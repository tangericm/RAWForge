import Foundation

/// The camera operations required by a station.
///
/// This is deliberately smaller than `CaptureRig`: the station knows the
/// order of its work, while AVFoundation remains an implementation detail of
/// the live adapter. Tests use an in-memory adapter through this same seam.
@MainActor
protocol StationCapturing: AnyObject {
    func prepareForFraming(_ sensor: SensorCapability.Sensor)
    func configure(_ sensor: SensorCapability.Sensor) async throws
    func lockWhiteBalance() async throws -> StationWhiteBalance
    func applyFocus(_ resolution: FocusResolution) async -> FrameRecord.Focus
    func capture(_ request: StationCaptureRequest,
                 progress: @escaping (String) -> Void) async throws -> SetShot
    func stop()
}

struct StationWhiteBalance {
    let set: [Float]
    let readBack: [Float]
}

struct StationCaptureRequest {
    let specs: [CaptureSpec]
    let sensor: SensorCapability.Sensor
    let whiteBalance: StationWhiteBalance
    let session: SessionRecord
    let stationIndex: Int
    let bracketIndex: Int
    let firing: ExecutionMode
    let focus: FrameRecord.Focus?
    let minimumGap: TimeInterval
    let timebase: CaptureTimebase
    var shouldStop: @MainActor () -> Bool = { false }
}

protocol StationPersisting: AnyObject {
    func open(capability: CapabilityReport) throws -> SessionRecord
    func loadSession(_ id: String) -> SessionRecord?
    func loadStationsDetailed(_ id: String) -> (stations: [StationRecord], unreadable: [String])
    func hasRoom(forFrames count: Int) -> Bool
    func writeMotionStream(_ samples: [MotionSample], sessionId: String,
                           station: Int) throws -> String
    func writeStation(_ station: StationRecord) throws
    func deleteStationFrames(sessionId: String, station: Int)
}

protocol StationMotionRecording: AnyObject {
    var requestedHz: Double { get }
    func start(timebase: CaptureTimebase)
    func stop()
    func summary(from start: TimeInterval, to end: TimeInterval) -> MotionSummary?
    func snapshot() -> [MotionSample]
    func latestTimestamp() -> TimeInterval?
}

@MainActor
protocol StationHealthChecking: AnyObject {
    var summary: String { get }
    func refresh()
    func faultIfUnhealthy() -> StationFault?
}

/// Time is an input to the workflow, not a hidden global. The live value uses
/// the system clocks; tests can advance instantly through waits.
struct StationClock {
    let date: () -> Date
    let uptime: () -> TimeInterval
    let sleep: (TimeInterval) async -> Void

    static let live = StationClock(
        date: Date.init,
        uptime: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in
            guard let nanoseconds = try? CaptureTiming.nanoseconds(for: seconds) else {
                logError(.flow, "clock refused an unsupported duration: \(seconds)")
                return
            }
            guard nanoseconds > 0 else { return }
            try? await Task.sleep(nanoseconds: nanoseconds)
        })

    /// Advances whenever time is read and never actually sleeps. This keeps a
    /// bounded wait bounded in a unit test without tying it to wall clock.
    static var immediate: StationClock {
        final class Box {
            var uptime: TimeInterval = 10
            var date = Date(timeIntervalSince1970: 10)
        }
        let box = Box()
        return StationClock(
            date: { box.date },
            uptime: {
                defer { box.uptime += 0.05 }
                return box.uptime
            },
            sleep: { seconds in
                box.uptime += max(seconds, 0)
                box.date = box.date.addingTimeInterval(max(seconds, 0))
            })
    }
}

/// Owns one station from declaration through bank or abort.
///
/// The public surface is the operator's actions and the state rendered by the
/// capture screen. Camera, motion, storage, health and time enter through
/// narrow internal seams, so lifecycle rules can be proved without hardware.
@MainActor
final class StationController: ObservableObject {
    private enum FlowError: Error, CustomStringConvertible {
        case noSupportedRungs(String)

        var description: String {
            switch self {
            case .noSupportedRungs(let message): return message
            }
        }
    }

    enum PrimaryAction: Equatable {
        case openSession
        case declareStation
        case beginSet(index: Int, total: Int)
        case closeStation
        case blocked(String)

        var title: String {
            switch self {
            case .openSession:              return "Open session"
            case .declareStation:           return "Declare station"
            case .beginSet(let i, let n):   return "Capture set \(i) of \(n)"
            case .closeStation:             return "Close station"
            case .blocked(let why):         return why
            }
        }

        var systemImage: String {
            switch self {
            case .openSession:    return "folder.badge.plus"
            case .declareStation: return "mappin.and.ellipse"
            case .beginSet:       return "camera.aperture"
            case .closeStation:   return "checkmark.seal"
            case .blocked:        return "exclamationmark.triangle"
            }
        }

        var isEnabled: Bool { if case .blocked = self { return false }; return true }
        var isTerminal: Bool { if case .closeStation = self { return true }; return false }
    }

    @Published var report: CapabilityReport?
    @Published var session: SessionRecord?
    @Published var status = "not probed"
    @Published var busy = false
    @Published private(set) var isCapturingTake = false
    @Published private(set) var progress = ""
    @Published var lastStation: StationRecord?

    @Published var phase: StationPhase = .noSession
    @Published var shotList = ShotList()
    @Published var pendingBrackets: [BracketRecord] = []
    @Published var lastFault: StationFault?
    @Published var stillnessLive = ""
    @Published var stationEstimateSeconds: Double?
    @Published var groupShotListBySensor = true
    @Published var focusPlan = FocusPlan()
    @Published var minimumGap: Double = 0
    @Published var dwell: Double = 0
    @Published var poseIntent = ""

    private(set) var stationIndex = 0
    private var stationOpenedAt: Date?
    private var pendingSwaps: [StationRecord.SwapRecord] = []
    private var focusContinuity = FocusContinuity()
    private var captureTimebase: CaptureTimebase?
    private var takeSnapshot: RecipeSnapshot?
    private var takeCorrelationID: UUID?
    private var stopRequested = false
    private var dwellTask: Task<Void, Never>?

    private let capture: StationCapturing
    private let persistence: StationPersisting
    private let motion: StationMotionRecording
    private let health: StationHealthChecking
    private let clock: StationClock

    init(capture: StationCapturing, persistence: StationPersisting,
         motion: StationMotionRecording, health: StationHealthChecking,
         clock: StationClock = .live) {
        self.capture = capture
        self.persistence = persistence
        self.motion = motion
        self.health = health
        self.clock = clock
    }

    var bracketCeiling: Int? {
        guard let value = report?.sharedBracketCeiling, value > 0 else { return nil }
        return value
    }

    func capability(_ sensor: SensorCapability.Sensor) -> SensorCapability? {
        report?.sensors.first { $0.sensor == sensor }
    }

    /// A single intent uses the existing station transaction from start to
    /// finish. No second camera engine or independently banked partial Take.
    func captureTake(recipe: RecipeSnapshot,
                     onRunReady: (SessionRecord) throws -> Void = { _ in }) async -> TakeOutcome {
        guard !busy, !isCapturingTake, !phase.isInStation else {
            return .blocked(message: "A capture is already in progress.")
        }
        guard let report else { return .blocked(message: "Camera checks have not finished.") }
        let validation = RecipeValidator.validate(recipe.capturedDefinition, against: report)
        guard validation.canCapture else {
            return .blocked(message: validation.blockers.map(\.message).joined(separator: " · "))
        }
        if let existing = session {
            do {
                guard existing.sessionType == "scene" else { throw ActiveRunStore.Failure.invalidRun }
                let validated = try ActiveRunStore.validate(sessionID: existing.sessionId,
                    loadSession: persistence.loadSession, loadStations: persistence.loadStationsDetailed)
                // Headers encode ISO-8601 dates at second precision. Compare
                // in that persisted domain, not against transient fractions.
                guard validated.session.openedAt.timeIntervalSince1970.rounded(.down)
                    == existing.openedAt.timeIntervalSince1970.rounded(.down) else {
                    throw ActiveRunStore.Failure.invalidRun
                }
                stationIndex = max(stationIndex, validated.run.nextTakeIndex - 1)
            } catch {
                return .blocked(message: "This Run changed or is unavailable. Finish it before starting another capture. Saved files have not been changed.")
            }
        }
        let correlation = UUID()
        isCapturingTake = true
        busy = true
        stopRequested = false
        defer {
            dwellTask?.cancel()
            dwellTask = nil
            takeSnapshot = nil
            takeCorrelationID = nil
            isCapturingTake = false
            busy = false
            startFraming()
        }
        logInfo(.flow, "take \(correlation) · recipe \(recipe.recipeID) v\(recipe.version) starting")
        if session == nil { openSession() }
        guard let session else { return .failed(correlationID: correlation, message: status) }
        do { try onRunReady(session) }
        catch { return .failed(correlationID: correlation, message: error.localizedDescription) }
        startFlow()
        shotList = ShotList(entries: recipe.capturedDefinition.renderedEntries(), cursor: 0)
        takeSnapshot = recipe
        takeCorrelationID = correlation
        declareStation()
        guard phase == .stationOpen else { return .failed(correlationID: correlation, message: status) }
        while canBeginSet {
            if stopRequested {
                abortStation(.abandoned)
                return .cancelled(correlationID: correlation)
            }
            await beginNextSet()
            guard phase == .stationOpen else {
                return lastFault == .abandoned
                    ? .cancelled(correlationID: correlation)
                    : .failed(correlationID: correlation, message: status)
            }
        }
        closeStation()
        guard let record = lastStation, record.correlationID == correlation else {
            return .failed(correlationID: correlation, message: status)
        }
        logInfo(.flow, "take \(correlation) complete")
        return .completed(correlationID: correlation, station: record)
    }

    func requestStop() {
        guard isCapturingTake else { return }
        stopRequested = true
        // An authored wait has no in-flight exposure to protect. Cancel only
        // that wait; camera requests continue to their existing safe boundary.
        dwellTask?.cancel()
        logInfo(.flow, "take \(takeCorrelationID?.uuidString ?? "unknown") stop requested at next safe boundary")
    }

    /// Diagnostic runs share the session's flat station namespace even though
    /// they do not participate in the scene workflow.
    func reserveStationIndex() -> Int {
        stationIndex += 1
        return stationIndex
    }

    var canDeclareStation: Bool { phase == .sessionOpen }
    var canBeginSet: Bool { phase == .stationOpen && shotList.current != nil }
    var canCloseStation: Bool { phase == .stationOpen && shotList.canClose }

    var primaryAction: PrimaryAction {
        if report?.canCapture != true { return .blocked("No Bayer sensor on this device") }
        switch phase {
        case .noSession:
            return .openSession
        case .sessionOpen:
            if shotList.entries.isEmpty { return .blocked("Add a set to the shot list") }
            return .declareStation
        case .stationOpen:
            if shotList.canClose { return .closeStation }
            if shotList.current != nil {
                return .beginSet(index: shotList.cursor + 1, total: shotList.entries.count)
            }
            return .blocked("Nothing left to shoot")
        case .swapping, .stilling, .settling, .capturing:
            return .blocked(phase.title)
        }
    }

    func performPrimaryAction() {
        switch primaryAction {
        case .openSession:    openSession(); startFlow()
        case .declareStation: declareStation()
        case .beginSet:       Task { await beginNextSet() }
        case .closeStation:   closeStation()
        case .blocked:        break
        }
    }

    func openSession() {
        guard let report, report.canCapture else { return }
        do {
            let opened = try persistence.open(capability: report)
            _ = beginCaptureSegment()
            session = opened
            stationIndex = 0
            status = "session \(opened.sessionId) open"
            logInfo(.store, "session \(opened.sessionId) opened · calibration "
                    + (opened.calibrationSessionId ?? "none referenced")
                    + " · \((opened.availableCapacityBytesAtOpen ?? 0) / 1_000_000) MB free")
        } catch {
            status = "session open failed — \(error)"
            logFailure(.store, "opening a session", error)
        }
    }

    func resumeRun(_ recovered: ActiveRunStore.RecoveredRun) throws {
        guard !busy, phase == .noSession, session == nil else { throw ActiveRunStore.Failure.busy }
        let validated = try ActiveRunStore.validate(sessionID: recovered.sessionID,
            loadSession: persistence.loadSession, loadStations: persistence.loadStationsDetailed)
        session = validated.session
        stationIndex = validated.run.nextTakeIndex - 1
        _ = beginCaptureSegment()
        shotList.cursor = 0
        resetFocusForNextPose()
        set(.sessionOpen)
        startFraming()
    }

    func recoverActiveRun(using store: ActiveRunStore) throws -> String? {
        let recovery = try store.recover(loadSession: persistence.loadSession,
                                        loadStations: persistence.loadStationsDetailed)
        if let run = recovery.run { try resumeRun(run) }
        return recovery.warning
    }

    /// Brings the flow up and is safe to call each time the capture tab appears.
    func startFlow() {
        guard !phase.isInStation else { return }
        set(session == nil ? .noSession : .sessionOpen)
        startFraming()
    }

    func startFraming() {
        guard !busy, !isCapturingTake, phase == .noSession || phase == .sessionOpen || phase == .stationOpen else { return }
        guard let sensor = shotList.current?.sensor ?? report?.usableSensors.first?.sensor,
              capability(sensor)?.isUsable == true else { return }
        capture.prepareForFraming(sensor)
    }

    func declareStation() {
        guard canDeclareStation, let captureTimebase else { return }
        health.refresh()
        if let fault = health.faultIfUnhealthy() {
            status = "not starting a station — \(fault.operatorNote)"
            logWarn(.flow, "station refused before it opened — \(fault.operatorNote); \(health.summary)")
            return
        }
        stationIndex += 1
        logInfo(.flow, "station \(stationIndex) declared · \(shotList.entries.count) set(s), "
                + "\(shotList.totalFrames) frame(s) · pose \(poseIntent.isEmpty ? "unset" : poseIntent)")
        stationOpenedAt = clock.date()
        pendingBrackets = []
        pendingSwaps = []
        lastFault = nil
        focusContinuity.reset()
        shotList.cursor = 0
        stationEstimateSeconds = SessionEstimate.forShotList(
            shotList.entries, minimumGap: isCapturingTake ? 0 : minimumGap,
            bracketCeiling: bracketCeiling).typicalSeconds
        motion.start(timebase: captureTimebase)
        set(.stationOpen)
    }

    func beginNextSet() async {
        guard canBeginSet, let entry = shotList.current,
              let session, let captureTimebase,
              let capability = capability(entry.sensor) else { return }

        logInfo(.flow, "set \(shotList.cursor + 1)/\(shotList.entries.count) — "
                + "\(entry.label), \(entry.frameCount) frame(s), "
                + entry.captureSet.firing.label.lowercased())

        health.refresh()
        if let fault = health.faultIfUnhealthy() { abortStation(fault); return }
        if !persistence.hasRoom(forFrames: entry.frameCount) {
            abortStation(.storageExhausted)
            return
        }

        busy = true
        defer {
            busy = isCapturingTake
            // `startFraming()` refuses while busy. Doing this inside the body
            // used to call it one line before `defer` cleared busy, leaving a
            // frozen preview after both success and abort.
            startFraming()
        }

        do {
            let stepDwell = isCapturingTake ? entry.dwellSeconds : dwell
            let stepGap = entry.captureSet.firing == .sequential
                ? (isCapturingTake ? entry.minimumGapSeconds ?? 0 : minimumGap) : 0
            // Legacy station controls do not pass through RecipeValidator.
            // Refuse invalid intent before configuring or firing the camera.
            _ = try CaptureTiming.nanoseconds(for: stepDwell)
            _ = try CaptureTiming.nanoseconds(for: stepGap)
            set(.swapping)
            let swapStart = clock.uptime()
            try await capture.configure(entry.sensor)
            let swapEnd = clock.uptime()
            pendingSwaps.append(StationRecord.SwapRecord(
                fromSensor: pendingSwaps.last?.toSensor,
                toSensor: entry.sensor.rawValue,
                durationSeconds: swapEnd - swapStart,
                motion: motion.summary(from: swapStart, to: swapEnd)?.offsettingWindow(
                    by: -captureTimebase.originUptime)))

            set(.stilling)
            let stillStart = clock.uptime()
            let settled = await waitForStillness()
            let stillWait = clock.uptime() - stillStart
            let now = clock.uptime()
            let motionAtFire = motion.summary(from: now - 0.4, to: now)?.offsettingWindow(
                by: -captureTimebase.originUptime)
            stillnessLive = ""

            set(.settling)
            if isCapturingTake && stopRequested { throw CaptureInterruption.stopRequested }
            if stepDwell > 0 {
                logTrace(.flow, String(format: "extra dwell %.2f s", stepDwell))
                let wait = Task { await clock.sleep(stepDwell) }
                dwellTask = wait
                await wait.value
                dwellTask = nil
                if isCapturingTake && stopRequested { throw CaptureInterruption.stopRequested }
            }

            let offset = entry.captureSet.perSensorEVOffsetStops[entry.sensor.rawValue] ?? 0
            let rendered = CaptureSet(
                name: entry.captureSet.name, version: entry.captureSet.version,
                specs: entry.captureSet.rendered(for: entry.sensor),
                generator: entry.captureSet.generator,
                perSensorEVOffsetStops: entry.captureSet.perSensorEVOffsetStops)
            let checked = rendered.validated(against: capability)
            guard !checked.kept.isEmpty else {
                throw FlowError.noSupportedRungs(
                    "every rung of \(entry.captureSet.name) is outside \(entry.sensor.rawValue)'s rails")
            }

            let whiteBalance = try await capture.lockWhiteBalance()
            let focus = await capture.applyFocus(
                focusContinuity.resolution(for: entry.sensor, plan: focusPlan))
            focusContinuity.record(focus, for: entry.sensor)
            logInfo(.rig, "focus \(focus.acquisition) on \(entry.sensor.rawValue) — \(focus.mode)"
                    + (focus.lensPosition.map { String(format: " at %.4f", $0) } ?? "")
                    + (focus.note.map { " · \($0)" } ?? ""))

            set(.capturing)
            if isCapturingTake && stopRequested { throw CaptureInterruption.stopRequested }
            let request = StationCaptureRequest(
                specs: checked.kept, sensor: entry.sensor,
                whiteBalance: whiteBalance, session: session,
                stationIndex: stationIndex,
                bracketIndex: pendingBrackets.count + 1,
                firing: entry.captureSet.firing, focus: focus,
                minimumGap: stepGap,
                timebase: captureTimebase,
                shouldStop: { [weak self] in self?.stopRequested == true })
            let shot = try await capture.capture(request) { [weak self] message in
                self?.progress = message
            }
            if isCapturingTake && stopRequested { throw CaptureInterruption.stopRequested }
            pendingBrackets.append(BracketRecord(
                bracketIndex: pendingBrackets.count + 1,
                sensor: entry.sensor.rawValue,
                sensorUniqueID: capability.uniqueID,
                captureSet: entry.captureSet,
                renderedSpecs: checked.kept,
                evOffsetStops: offset,
                executionMode: entry.captureSet.firing.rawValue,
                bracketRequestSizes: shot.bracketRequestSizes,
                droppedRungs: checked.dropped,
                minimumInterFrameGapSeconds: stepGap > 0 ? stepGap : nil,
                stillnessSettled: settled,
                stillnessWaitSeconds: stillWait,
                motionAtFire: motionAtFire,
                dwellSeconds: stepDwell > 0 ? stepDwell : nil,
                note: nil,
                frames: shot.frames))

            capture.stop()
            shotList.cursor += 1
            progress = ""
            logInfo(.flow, String(format: "set banked — %d frame(s), stillness %@ after %.2f s",
                                  shot.frames.count, settled ? "settled" : "elevated", stillWait))
            set(.stationOpen)
        } catch CaptureInterruption.stopRequested {
            capture.stop()
            progress = ""
            abortStation(.abandoned)
        } catch {
            capture.stop()
            progress = ""
            logFailure(.flow, "set \(shotList.cursor + 1) on \(entry.sensor.rawValue)", error)
            abortStation(.captureError, detail: "\(error)")
        }
    }

    func closeStation() {
        guard canCloseStation, let session, let captureTimebase else { return }
        motion.stop()
        let samples = motion.snapshot()
        let streamFile = samples.isEmpty ? nil
            : try? persistence.writeMotionStream(
                samples, sessionId: session.sessionId, station: stationIndex)
        let record = StationRecord(
            stationIndex: stationIndex,
            sessionId: session.sessionId,
            openedAt: stationOpenedAt ?? clock.date(),
            closedAt: clock.date(),
            brackets: pendingBrackets,
            captureTimebase: captureTimebase,
            sensorSwaps: pendingSwaps,
            motion: samples.isEmpty ? nil : MotionSummary.over(
                samples, from: samples.first!.t, to: samples.last!.t),
            motionStreamFile: streamFile,
            motionRequestedHz: motion.requestedHz,
            poseIntent: poseIntent,
            estimatedSeconds: stationEstimateSeconds,
            recipeSnapshot: takeSnapshot, correlationID: takeCorrelationID)
        do {
            try persistence.writeStation(record)
            lastStation = record
            let frameCount = record.brackets.reduce(0) { $0 + $1.frames.count }
            status = "station \(stationIndex) banked — \(frameCount) frames"
            logInfo(.flow, String(format: "station %d closed — %d frame(s), %d bracket(s), "
                                  + "%.1f s wall clock (estimated %.1f s)",
                                  stationIndex, frameCount, record.brackets.count,
                                  record.closedAt.timeIntervalSince(record.openedAt),
                                  stationEstimateSeconds ?? 0))
        } catch {
            abortStation(.captureError, detail: "Could not save the Take record: \(error)")
            return
        }
        pendingBrackets = []
        pendingSwaps = []
        resetFocusForNextPose()
        set(.sessionOpen)
        startFraming()
    }

    func abortStation(_ fault: StationFault, detail: String? = nil) {
        guard let session else { return }
        logError(.flow, "station \(stationIndex) ABORTED — \(fault.operatorNote)"
                 + (detail.map { ": \($0)" } ?? "")
                 + " · \(pendingBrackets.count) bracket(s) discarded, \(health.summary)")
        motion.stop()
        persistence.deleteStationFrames(sessionId: session.sessionId, station: stationIndex)
        pendingBrackets = []
        pendingSwaps = []
        resetFocusForNextPose()
        lastFault = fault
        set(.sessionOpen)
        startFraming()
        status = "station \(stationIndex) ABORTED — \(fault.operatorNote)"
            + (detail.map { ": \($0)" } ?? "")
            + ". Frames deleted; banked stations survive."
    }

    func closeSession() {
        guard phase == .sessionOpen else { return }
        session = nil
        captureTimebase = nil
        shotList.cursor = 0
        resetFocusForNextPose()
        set(.noSession)
    }

    func addToShotList(_ set: CaptureSet, sensor: SensorCapability.Sensor) {
        var entries = shotList.entries
        entries.append(ShotListEntry(index: entries.count, sensor: sensor, captureSet: set))
        applyShotList(entries)
        logInfo(.flow, "shot list: added \(set.name) v\(set.version) on \(sensor.rawValue) "
                + "(\(set.specs.count) frames)")
    }

    func removeFromShotList(at offsets: IndexSet) {
        var entries = shotList.entries
        entries.remove(atOffsets: offsets)
        applyShotList(entries)
    }

    func moveInShotList(from source: IndexSet, to destination: Int) {
        var entries = shotList.entries
        entries.move(fromOffsets: source, toOffset: destination)
        groupShotListBySensor = false
        applyShotList(entries)
    }

    func regroupShotList() { applyShotList(shotList.entries) }

    func clearShotList() {
        shotList = ShotList()
        ShotListStore.clear()
        logInfo(.flow, "shot list cleared")
    }

    func restoreShotList() {
        guard let stored = ShotListStore.load() else { return }
        groupShotListBySensor = stored.groupedBySensor
        shotList = ShotList(entries: stored.entries, cursor: 0)
    }

    private func applyShotList(_ entries: [ShotListEntry]) {
        shotList.entries = groupShotListBySensor
            ? ShotList.grouped(entries) : ShotList.authored(entries)
        shotList.cursor = min(shotList.cursor, shotList.entries.count)
        ShotListStore.save(shotList, grouped: groupShotListBySensor)
    }

    private func waitForStillness() async -> Bool {
        let settleWindow: TimeInterval = 0.4
        let start = clock.uptime()
        var inBand = false
        while clock.uptime() - start < settleWindow {
            let now = clock.uptime()
            if let summary = motion.summary(from: now - 0.3, to: now),
               summary.sampleCount > 4 {
                inBand = summary.advisory == .tripodLike
                stillnessLive = String(format: "gyro p99 %.4f — %@", summary.gyroP99,
                                       inBand ? "in the tripod band"
                                              : "elevated, recorded not gated")
                if inBand { return true }
            }
            await clock.sleep(0.05)
        }
        let now = clock.uptime()
        if let summary = motion.summary(from: now - 0.3, to: now) {
            inBand = summary.advisory == .tripodLike
        }
        return inBand
    }

    private func resetFocusForNextPose() {
        focusPlan = FocusPlan()
        focusContinuity.reset()
    }

    private func beginCaptureSegment() -> CaptureTimebase {
        let created = CaptureTimebase(
            segmentID: UUID().uuidString,
            originUptime: clock.uptime())
        captureTimebase = created
        return created
    }

    private func set(_ newPhase: StationPhase) {
        if phase != newPhase { logInfo(.flow, "\(phase.rawValue) → \(newPhase.rawValue)") }
        phase = newPhase
    }
}
