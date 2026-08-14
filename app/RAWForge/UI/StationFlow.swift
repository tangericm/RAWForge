import AVFoundation
import Foundation

/// The station flow's transitions, layered over the capture engine.
///
/// Each phase exists because something must finish before the next may start.
/// The waits are not prompts: there is no override on stillness and nothing
/// fires before the exposure has settled.
@MainActor
extension CaptureModel {

    var canDeclareStation: Bool { phase == .sessionOpen }
    var canBeginSet: Bool { phase == .stationOpen && shotList.current != nil }
    var canCloseStation: Bool { phase == .stationOpen && shotList.canClose }

    /// What the one big button does right now.
    ///
    /// There is exactly one action available at any moment, and deciding which
    /// belongs here rather than in the view: the rule is the flow's, and a
    /// screen that works it out from four booleans will eventually disagree
    /// with the flow about what is legal.
    enum PrimaryAction: Equatable {
        case openSession
        case declareStation
        case beginSet(index: Int, total: Int)
        case closeStation
        /// Nothing can be done yet, and this says what is missing.
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
        /// Closing a station is the one that banks data, so it reads as
        /// completion rather than as another shutter press.
        var isTerminal: Bool { if case .closeStation = self { return true }; return false }
    }

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

    /// Brings the flow up, and is safe to call again.
    ///
    /// It runs from the capture screen's `onAppear`, which fires every time that
    /// tab is returned to — and checking the console mid-station is exactly what
    /// the console is for. Resetting the phase unconditionally would have
    /// stranded an open station's buffered brackets: the phase would say
    /// `sessionOpen` while frames sat in memory belonging to a station that
    /// could no longer be closed or aborted.
    func startFlow() {
        guard !phase.isInStation else { return }
        phase = session == nil ? .noSession : .sessionOpen
        flowNote = phase.note
        startFraming()
    }

    /// Framing runs between stations, when the operator is walking to the next
    /// pose and needs to see where the camera points. Never touched mid-station:
    /// the capture path owns the session once a set begins.
    func startFraming() {
        guard !busy, phase == .sessionOpen || phase == .stationOpen else { return }
        // The sensor about to be shot, or — with nothing planned yet — whichever
        // one this device offers first, so the viewfinder is live while the shot
        // list is still being built.
        guard let sensor = shotList.current?.sensor ?? report?.usableSensors.first?.sensor,
              capability(sensor)?.isUsable == true else { return }
        rig.prepareForFraming(sensor)
    }

    /// Stations accumulate rather than being planned up front (#10), so this is
    /// an explicit act at the pose, not a slot filled in beforehand.
    func declareStation() {
        guard canDeclareStation else { return }
        health.refresh()
        if let fault = health.faultIfUnhealthy() {
            status = "not starting a station — \(fault.operatorNote)"
            logWarn(.flow, "station refused before it opened — \(fault.operatorNote); \(health.summary)")
            return
        }
        stationIndex += 1
        logInfo(.flow, "station \(stationIndex) declared · \(shotList.entries.count) set(s), "
                + "\(shotList.totalFrames) frame(s) · pose \(poseIntent.isEmpty ? "unset" : poseIntent)")
        stationOpenedAt = Date()
        pendingBrackets = []
        pendingSwaps = []
        lastFault = nil
        // A pose is the scope of a focus decision, so what the last station's
        // sensors settled at has no bearing on this one — the phone has moved.
        focusContinuity.reset()
        lastFocus = nil
        shotList.cursor = 0
        stationEstimateSeconds = SessionEstimate.forShotList(
            shotList.entries, minimumGap: minimumGap,
            bracketCeiling: bracketCeiling).typicalSeconds
        motionRecorder.start()
        set(.stationOpen)
    }

    /// Walks one shot-list entry through swap, still, settle and capture.
    func beginNextSet() async {
        guard canBeginSet, let entry = shotList.current,
              let session, let cap = capability(entry.sensor) else { return }

        logInfo(.flow, "set \(shotList.cursor + 1)/\(shotList.entries.count) — "
                + "\(entry.label), \(entry.frameCount) frame(s), \(entry.captureSet.firing.label.lowercased())")

        // Faults land at a set boundary rather than halfway through a bracket.
        health.refresh()
        if let fault = health.faultIfUnhealthy() { abortStation(fault); return }
        if !SessionStore.hasRoom(forFrames: entry.frameCount) {
            abortStation(.storageExhausted); return
        }

        busy = true
        defer { busy = false }

        do {
            set(.swapping)
            let swapStart = ProcessInfo.processInfo.systemUptime
            try await rig.configure(entry.sensor)
            await rig.startSessionAndWait()
            let swapEnd = ProcessInfo.processInfo.systemUptime
            pendingSwaps.append(StationRecord.SwapRecord(
                fromSensor: pendingSwaps.last?.toSensor, toSensor: entry.sensor.rawValue,
                durationSeconds: swapEnd - swapStart,
                motion: motionRecorder.summary(from: swapStart, to: swapEnd)))

            // A wait, not a prompt. It cannot be overridden, and it never
            // deletes anything — motion is an advisory (#10, amended), so this
            // resolves either when the device is still or when waiting longer
            // has stopped being informative.
            set(.stilling)
            let stillStart = ProcessInfo.processInfo.systemUptime
            let settled = await waitForStillness()
            let stillWait = ProcessInfo.processInfo.systemUptime - stillStart
            let motionAtFire = motionRecorder.summary(
                from: ProcessInfo.processInfo.systemUptime - 0.4,
                to: ProcessInfo.processInfo.systemUptime)
            stillnessLive = ""

            set(.settling)
            // An operator-chosen hold on top of the measured transient decay,
            // for a mount that is known to ring longer than a finger-lift.
            if dwell > 0 {
                logTrace(.flow, String(format: "extra dwell %.2f s", dwell))
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            }
            let offset = entry.captureSet.perSensorEVOffsetStops[entry.sensor.rawValue] ?? 0
            let rendered = CaptureSet(
                name: entry.captureSet.name, version: entry.captureSet.version,
                specs: entry.captureSet.rendered(for: entry.sensor),
                generator: entry.captureSet.generator,
                perSensorEVOffsetStops: entry.captureSet.perSensorEVOffsetStops)
            let checked = rendered.validated(against: cap)
            guard !checked.kept.isEmpty else {
                throw CaptureRig.RigError.unsupported(
                    "every rung of \(entry.captureSet.name) is outside \(entry.sensor.rawValue)'s rails")
            }
            let wb = try await rig.lockWhiteBalance()

            // Focus is taken here, beside the other two locks, because it is
            // the same kind of thing: a parameter that would otherwise drift
            // between frames with nothing in the log saying so (#18).
            //
            // A sensor returning for a second set at this station gets its own
            // earlier measurement put back exactly; a sensor arriving for the
            // first time acquires fresh. Never throws — a lens that cannot be
            // held is recorded as such rather than costing the station.
            let focus = await rig.applyFocus(
                focusContinuity.resolution(for: entry.sensor, plan: focusPlan))
            focusContinuity.record(focus, for: entry.sensor)
            lastFocus = focus
            logInfo(.rig, "focus \(focus.acquisition) on \(entry.sensor.rawValue) — "
                    + "\(focus.mode)"
                    + (focus.lensPosition.map { String(format: " at %.4f", $0) } ?? "")
                    + (focus.note.map { " · \($0)" } ?? ""))

            set(.capturing)
            let shot = try await shoot(checked.kept, sensor: entry.sensor, wb: wb,
                                       session: session, station: stationIndex,
                                       bracketIndex: pendingBrackets.count + 1,
                                       firing: entry.captureSet.firing,
                                       focus: focus)
            pendingBrackets.append(BracketRecord(
                bracketIndex: pendingBrackets.count + 1, sensor: entry.sensor.rawValue,
                sensorUniqueID: cap.uniqueID, captureSet: entry.captureSet,
                renderedSpecs: checked.kept, evOffsetStops: offset,
                executionMode: entry.captureSet.firing.rawValue,
                bracketRequestSizes: shot.bracketRequestSizes,
                droppedRungs: checked.dropped,
                minimumInterFrameGapSeconds: minimumGap > 0 ? minimumGap : nil,
                stillnessSettled: settled, stillnessWaitSeconds: stillWait,
                motionAtFire: motionAtFire,
                dwellSeconds: dwell > 0 ? dwell : nil, note: nil, frames: shot.frames))

            rig.stopSession()
            shotList.cursor += 1
            logInfo(.flow, String(format: "set banked — %d frame(s), stillness %@ after %.2f s",
                                  shot.frames.count, settled ? "settled" : "elevated", stillWait))
            set(.stationOpen)
            startFraming()
        } catch {
            rig.stopSession()
            logFailure(.flow, "set \(shotList.cursor + 1) on \(entry.sensor.rawValue)", error)
            abortStation(.captureError, detail: "\(error)")
        }
    }

    /// Nothing lands until the whole shot list is done.
    func closeStation() {
        guard canCloseStation, let session else { return }
        motionRecorder.stop()
        let samples = motionRecorder.snapshot()
        let streamFile = samples.isEmpty ? nil
            : try? SessionStore.writeMotionStream(samples, sessionId: session.sessionId, station: stationIndex)
        let record = StationRecord(
            stationIndex: stationIndex, sessionId: session.sessionId,
            openedAt: stationOpenedAt ?? Date(), closedAt: Date(),
            brackets: pendingBrackets, sensorSwaps: pendingSwaps,
            motion: samples.isEmpty ? nil : MotionSummary.over(
                samples, from: samples.first!.t, to: samples.last!.t),
            motionStreamFile: streamFile,
            motionRequestedHz: motionRecorder.requestedHz,
            poseIntent: poseIntent,
            estimatedSeconds: stationEstimateSeconds)
        do {
            try SessionStore.writeStation(record)
            lastStation = record
            let frames = record.brackets.reduce(0) { $0 + $1.frames.count }
            status = "station \(stationIndex) banked — \(frames) frames"
            logInfo(.flow, String(format: "station %d closed — %d frame(s), %d bracket(s), "
                                  + "%.1f s wall clock (estimated %.1f s)",
                                  stationIndex, frames, record.brackets.count,
                                  record.closedAt.timeIntervalSince(record.openedAt),
                                  stationEstimateSeconds ?? 0))
        } catch {
            status = "could not write station \(stationIndex) — \(error)"
            // The frames are on disk and the record describing them is not,
            // which is the one inconsistency the design is meant to preclude.
            logError(.flow, "STATION RECORD NOT WRITTEN for station \(stationIndex) — \(error). "
                     + "Its frames are on disk with no log describing them.")
        }
        pendingBrackets = []
        pendingSwaps = []
        set(.sessionOpen)
        startFraming()
    }

    /// One rule: a hard fault flags, aborts the station, and deletes its frames.
    /// Stations already banked survive.
    func abortStation(_ fault: StationFault, detail: String? = nil) {
        guard let session else { return }
        logError(.flow, "station \(stationIndex) ABORTED — \(fault.operatorNote)"
                 + (detail.map { ": \($0)" } ?? "")
                 + " · \(pendingBrackets.count) bracket(s) discarded, \(health.summary)")
        motionRecorder.stop()
        SessionStore.deleteStationFrames(sessionId: session.sessionId, station: stationIndex)
        pendingBrackets = []
        pendingSwaps = []
        lastFault = fault
        set(.sessionOpen)
        startFraming()
        status = "station \(stationIndex) ABORTED — \(fault.operatorNote)"
            + (detail.map { ": \($0)" } ?? "") + ". Frames deleted; banked stations survive."
    }

    func closeSession() {
        guard phase == .sessionOpen else { return }
        session = nil
        shotList.cursor = 0
        set(.noSession)
    }

    // MARK: - Waits

    /// Polls the live motion stream until the device settles into the tripod
    /// band, or until waiting longer stops being informative. There is no
    /// override, and there is no deletion either — this is a wait.
    /// Lets the tap transient decay, then fires. Returns whether the device was
    /// in the tripod band at the moment it fired.
    ///
    /// The duration is measured, not chosen. Replaying six real motion streams
    /// through successive 0.2 s windows from station open: the first window
    /// runs 1.5-4.3x the steady state on every mount, and by 0.2-0.4 s each has
    /// reached its own baseline. **0.4 s is how long a finger-lift takes to
    /// decay.**
    ///
    /// It deliberately does **not** wait for an absolute stillness band. That
    /// was the original design and replaying the same streams showed it never
    /// resolves by hand — 0.0% of handheld windows fall in the tripod band, on
    /// all three handheld runs — so it would have burned a four-second timeout
    /// on every set, every time, for nothing.
    ///
    /// Nor does it try to detect an ongoing disturbance and wait it out. A
    /// sustained bump is indistinguishable from handheld steady state in a
    /// short window, because the disturbance defines the baseline any test
    /// would compare against; a simulated continuous shake passes every
    /// plateau rule tried. That is the same wall #10's amendment hit, and the
    /// same conclusion applies: motion is recorded and the workstation judges
    /// it, because here the app genuinely cannot.
    private func waitForStillness() async -> Bool {
        let settleWindow: TimeInterval = 0.4
        let start = ProcessInfo.processInfo.systemUptime
        var inBand = false
        while ProcessInfo.processInfo.systemUptime - start < settleWindow {
            let now = ProcessInfo.processInfo.systemUptime
            if let m = motionRecorder.summary(from: now - 0.3, to: now), m.sampleCount > 4 {
                inBand = m.advisory == .tripodLike
                stillnessLive = String(format: "gyro p99 %.4f — %@", m.gyroP99,
                                       inBand ? "in the tripod band" : "elevated, recorded not gated")
                // Already still: the transient is over and nothing is gained by
                // holding the operator longer.
                if inBand { return true }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let m = motionRecorder.summary(from: now - 0.3, to: now) {
            inBand = m.advisory == .tripodLike
        }
        return inBand
    }

    /// Every transition is logged. The phase sequence is the single most useful
    /// thing in the log when a station misbehaves: it says whether the swap
    /// completed, whether the wait ran, and where it stopped.
    private func set(_ p: StationPhase) {
        if phase != p { logInfo(.flow, "\(phase.rawValue) → \(p.rawValue)") }
        phase = p
        flowNote = p.note
    }
}
