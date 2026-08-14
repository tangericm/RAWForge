import AVFoundation
import ImageIO
import Foundation

/// Carries which rung failed and how many had already landed. A station still
/// aborts and deletes (#10), but the log should say how far it got.
struct SequenceFault: Error {
    let sensor: String
    let frameIndex: Int
    let completed: Int
    let underlying: Error
}

@MainActor
final class CaptureModel: ObservableObject {
    /// Settable within the module so the flow's state machine can be driven in
    /// tests without a camera. The probe is the only thing that writes it in
    /// the app itself.
    @Published var report: CapabilityReport?
    @Published var session: SessionRecord?
    @Published var status: String = "not probed"
    @Published private(set) var cameraDenied = false
    @Published var busy = false
    @Published private(set) var progress: String = ""
    @Published var lastStation: StationRecord?

    // MARK: - Station flow (#10, per the prototype)

    @Published var phase: StationPhase = .noSession
    @Published var shotList = ShotList()
    @Published var stationOpenedAt: Date?
    @Published var flowNote: String = ""
    /// Buffered until the station closes: the write unit and the abort unit are
    /// the same thing, so nothing lands until the whole shot list is done.
    @Published var pendingBrackets: [BracketRecord] = []
    @Published var pendingSwaps: [StationRecord.SwapRecord] = []
    @Published var lastFault: StationFault?
    /// Live during a stillness wait, so the operator can see whether steadying
    /// will help or the clock is simply running.
    @Published var stillnessLive: String = ""
    @Published var stationEstimateSeconds: Double?

    @Published var groupShotListBySensor = true

    // MARK: - Focus (#18)

    /// Chosen at the pose with the preview visible, never authored into a
    /// protocol — a lens position has no meaning away from the thing it was
    /// focused on. Reset when a station closes, because a pose is the scope of
    /// a focus decision.
    @Published var focusPlan = FocusPlan()

    /// What each sensor actually settled at, this station. Not published: it is
    /// bookkeeping for the flow, not something the interface reads.
    var focusContinuity = FocusContinuity()

    /// The last lock taken, for the capture screen to show. A station where
    /// this says `notLocked` is one whose frames may have drifted.
    @Published var lastFocus: FrameRecord.Focus?

    /// Adds one protocol on one sensor. Named directly rather than assembled
    /// from two pickers and a button: choosing what to shoot and where is a
    /// single decision, and making it three interactions was the main thing
    /// wrong with the plan screen.
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

    /// Moving an entry *is* authoring an order, so it turns grouping off rather
    /// than silently undoing the move on the next regroup (#8 makes authored
    /// order the override, not a mode you have to find).
    func moveInShotList(from source: IndexSet, to destination: Int) {
        var entries = shotList.entries
        entries.move(fromOffsets: source, toOffset: destination)
        groupShotListBySensor = false
        applyShotList(entries)
    }

    private func applyShotList(_ entries: [ShotListEntry]) {
        shotList.entries = groupShotListBySensor ? ShotList.grouped(entries) : ShotList.authored(entries)
        shotList.cursor = min(shotList.cursor, shotList.entries.count)
        ShotListStore.save(shotList, grouped: groupShotListBySensor)
    }

    /// Re-applies the current grouping rule to the existing entries — what the
    /// grouping toggle does. Turning it back on discards an authored order,
    /// which is the honest behaviour: the two are alternatives, not layers.
    func regroupShotList() {
        applyShotList(shotList.entries)
    }

    func clearShotList() {
        shotList = ShotList()
        ShotListStore.clear()
        logInfo(.flow, "shot list cleared")
    }

    /// Restores the plan but never the cursor: on relaunch any station in
    /// flight is gone, so a half-walked cursor would describe a station that
    /// never existed.
    func restoreShotList() {
        guard let stored = ShotListStore.load() else { return }
        groupShotListBySensor = stored.groupedBySensor
        shotList = ShotList(entries: stored.entries, cursor: 0)
    }

    /// Only sequential sets can honour this, so the control that sets it only
    /// appears when the shot list contains one.
    @Published var minimumGap: Double = 0
    /// Extra hold before the first frame of a set, on top of the measured 0.4 s
    /// transient decay. Optional (#8) — zero means fire as soon as the stillness
    /// wait resolves, which is the common case.
    @Published var dwell: Double = 0

    /// The protocol in force for the bench runs — the dark-frame calibration and
    /// the instrument checks, which shoot a set without a shot list. Nil is a
    /// legitimate state and the screens that need one say so rather than
    /// silently defaulting: #8's "no silent default" means a session is never
    /// shot under a protocol nobody chose.
    @Published var selectedProtocol: CaptureSet?
    @Published var savedProtocols: [CaptureSet] = []
    /// Per-sensor EV offset in stops (#8). The sensors are not interchangeable.
    @Published var evOffsets: [String: Double] = [:]
    /// Pose intent — the mounting condition or scene note (#9). Item 21 needs
    /// three conditions distinguishable in the log, not just in memory.
    @Published var poseIntent: String = ""

    /// Offered as presets so the common conditions are spelled consistently.
    /// Free text stays available — the point is to make the ordinary case
    /// one tap, not to constrain what a station can be.
    static let poseIntentPresets = [
        "tripod-rigid", "tripod-soft", "handheld",
        "dark-frame", "calibration",
    ]
    /// A station is a pose and may span sensors (#7). The shot list names which
    /// ones; pinning to a single sensor is just a list of length one, not a
    /// separate mode.
    @Published var selectedSensors: Set<SensorCapability.Sensor> = [.wide]

    let rig = CaptureRig()
    let motionRecorder = MotionRecorder()
    let health = DeviceHealth()
    var stationIndex = 0

    /// Characterising the instrument, which is not shooting a scene (#28).
    ///
    /// A separate observable rather than more properties here: the runs share
    /// the rig and nothing else, and they were a third of this file. Views that
    /// need them observe `bench` directly — nested `ObservableObject`s do not
    /// republish, and pretending otherwise is how a screen stops updating.
    lazy var bench = BenchModel(rig: rig, motionRecorder: motionRecorder)

    func capability(_ s: SensorCapability.Sensor) -> SensorCapability? {
        report?.sensors.first { $0.sensor == s }
    }

    /// Frames per hardware request, taken as the smallest ceiling across the
    /// usable sensors — the conservative number, since a shot list may span
    /// them and a plan should not promise the best case.
    var bracketCeiling: Int? {
        guard let c = report?.sharedBracketCeiling, c > 0 else { return nil }
        return c
    }

    /// The bench runs sweep sensors in the canonical order.
    var orderedSensors: [SensorCapability.Sensor] {
        SensorCapability.Sensor.allCases.filter { selectedSensors.contains($0) }
    }

    /// The set the bench runs will shoot. Nil until a protocol is chosen — the
    /// screens that need one refuse rather than inventing a default.
    var currentSet: CaptureSet? {
        guard let p = selectedProtocol else { return nil }
        return CaptureSet(name: p.name, version: p.version, specs: p.specs,
                          generator: p.generator, perSensorEVOffsetStops: evOffsets)
    }

    func refreshProtocols() {
        savedProtocols = ProtocolLibrary.all()
        // A protocol edited in the sheet is a new version; the selection has to
        // follow it or the bench keeps shooting the stale definition.
        if let name = selectedProtocol?.name { selectedProtocol = ProtocolLibrary.load(named: name) }
    }

    // MARK: - Probe

    func probe() async {
        guard await requestCamera() else {
            cameraDenied = true
            status = "camera permission denied — no sensor can be probed"
            logError(.app, "camera permission denied — no sensor can be probed")
            return
        }
        status = "probing sensors…"
        let result = await Task.detached(priority: .userInitiated) { CapabilityProbe.run() }.value
        report = result
        if let first = result.usableSensors.first { selectedSensors = [first.sensor] }
        status = result.canCapture
            ? "\(result.usableSensors.count) of \(result.sensors.count) sensors deliver Bayer"
            : "no sensor on this device delivers Bayer RAW — capture refused"
        logInfo(.probe, "probed \(result.sensors.count) sensor(s), "
                + "\(result.usableSensors.count) deliver Bayer")
        for s in result.sensors {
            if s.isUsable {
                logInfo(.probe, "\(s.sensor.rawValue) usable · \(s.bayerFormatFourCC ?? "?") · "
                        + "bracket max \(s.maxBracketedCapturePhotoCount)")
            } else {
                logWarn(.probe, "\(s.sensor.rawValue) unusable — \(s.exclusionReason ?? "no reason given")")
            }
        }
    }

    func openSession() {
        guard let report, report.canCapture else { return }
        do {
            // A scene session records which calibration it was shot under and
            // how old it was, so a stale one is visible instead of assumed (#15).
            let opened = try SessionStore.open(
                capability: report, calibration: SessionStore.latestCalibration())
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

    // MARK: - Firing a set

    func shoot(_ specs: [CaptureSpec], sensor: SensorCapability.Sensor,
                       wb: (set: [Float], readBack: [Float]),
                       session: SessionRecord, station: Int, bracketIndex: Int,
                       firing: ExecutionMode,
                       focus: FrameRecord.Focus? = nil) async throws -> SetShot {
        var frames: [FrameRecord] = []
        var previousTimestamp: Double?
        var requestSizes: [Int]?

        /// Written the moment it arrives, then the photo is released. A
        /// 336-frame dark mirror (#15) could never hold its photos in memory.
        func bank(_ photo: AVCapturePhoto, _ spec: CaptureSpec, device: FrameRecord.Exposure?) throws {
            let index = frames.count + 1
            guard let data = photo.fileDataRepresentation() else {
                logError(.capture, "frame \(index) on \(sensor.rawValue): fileDataRepresentation() "
                         + "returned nil — the photo arrived but carries no file")
                throw CaptureRig.RigError.captureFailed("frame \(index): fileDataRepresentation() returned nil")
            }
            let filename = SessionStore.frameFilename(
                sessionId: session.sessionId, station: station,
                bracket: bracketIndex, frame: index, sensor: sensor.rawValue)
            do {
                _ = try SessionStore.writeFrame(data, named: filename, sessionId: session.sessionId)
            } catch {
                logFailure(.store, "writing \(filename) (\(data.count / 1_000_000) MB)", error)
                throw error
            }

            // Frame size is scene-dependent, so the worst case cannot be settled
            // by a characterisation run pointed at whatever was in front of it.
            // It is learned from real work instead, and only ever rises.
            DeviceProfile.noteObservedFrame(bytes: data.count)

            let witness = DNGMetadata.read(data)
            let clip = ClippingStats.compute(
                from: photo, bayerFormat: rig.bayerFormat,
                activeArea: witness.activeArea,
                blackLevel: witness.blackLevel?.first,
                whiteLevel: witness.whiteLevel?.first)
            logTrace(.capture, String(format: "frame %d/%d %@ · %.1f MB · asked %.6fs ISO %.0f, "
                                      + "DNG says %.6fs ISO %d",
                                      index, specs.count, filename, Double(data.count) / 1_000_000,
                                      spec.shutterSeconds, spec.iso,
                                      witness.exposureTimeSeconds ?? 0, witness.iso ?? 0))
            // Statistics silently absent is how a clipping table ends up empty
            // three days later with nothing saying why.
            if let why = clip.unavailableReason {
                logWarn(.capture, "frame \(index): no clipping statistics — \(why)")
            }

            let stamp = photo.timestamp.isValid ? photo.timestamp.seconds : nil
            let uptimeNow = ProcessInfo.processInfo.systemUptime
            // The exposure window has already elapsed by the time the photo is
            // delivered, so the samples covering it are already in the buffer.
            let exposureWindow = stamp.map { ($0, $0 + spec.shutterSeconds) }
            // Wide enough to hold a usable sample count at any shutter speed.
            // Explicitly a neighbourhood, not the exposure — the bounds travel
            // with the summary so the distinction survives into the log.
            let neighbourhood = stamp.map { ($0 - 0.1, $0 + spec.shutterSeconds + 0.1) }
            frames.append(FrameRecord(
                frameIndex: index, filename: filename, sensor: sensor.rawValue,
                requested: FrameRecord.Exposure(
                    shutterSeconds: spec.shutterSeconds, iso: spec.iso, whiteBalanceGains: wb.set),
                deviceAchieved: device,
                photoAchieved: Self.exposure(from: photo, wb: wb.readBack),
                dng: witness,
                // The lock was taken once for the whole set, so every frame
                // carries the same record — which is the point. A set whose
                // frames disagree about focus is a set where the lock failed.
                focus: focus,
                zoomFactor: rig.currentZoomFactor,
                capturedAtUptime: ProcessInfo.processInfo.systemUptime,
                capturedAt: Date(),
                photoTimestampSeconds: stamp,
                gapFromPreviousSeconds: zip(stamp, previousTimestamp).map { $0 - $1 },
                clipping: clip,
                motion: exposureWindow.flatMap { motionRecorder.summary(from: $0.0, to: $0.1) },
                motionNeighbourhood: neighbourhood.flatMap { motionRecorder.summary(from: $0.0, to: $0.1) },
                uptimeAtDelivery: uptimeNow,
                latestMotionTimestamp: motionRecorder.latestTimestamp()))
            previousTimestamp = stamp ?? previousTimestamp
        }

        switch firing {
        case .sequential:
            var lastFired: TimeInterval?
            for (i, spec) in specs.enumerated() {
                progress = "\(sensor.rawValue) sequential \(i + 1)/\(specs.count) — \(spec.shutterLabel)"
                do {
                    let achieved = try await rig.lockExposure(
                        shutterSeconds: spec.shutterSeconds, iso: spec.iso)
                    // Only sequential can honour a gap: a burst is one request
                    // with nowhere to insert a wait.
                    if let last = lastFired, minimumGap > 0 {
                        let elapsed = ProcessInfo.processInfo.systemUptime - last
                        if elapsed < minimumGap {
                            try? await Task.sleep(nanoseconds: UInt64((minimumGap - elapsed) * 1_000_000_000))
                        }
                    }
                    lastFired = ProcessInfo.processInfo.systemUptime
                    try bank(try await rig.captureSingle(), spec, device: achieved)
                } catch {
                    throw SequenceFault(sensor: sensor.rawValue, frameIndex: i + 1,
                                        completed: frames.count, underlying: error)
                }
            }
        case .hardwareBracket:
            progress = "\(sensor.rawValue) bracket of \(specs.count)"
            do {
                // Banked as each request lands, so two requests' worth of Bayer
                // buffers are never alive at once. No device read-back here:
                // the device is never reconfigured mid-bracket, so it would
                // report the last rung for every frame.
                requestSizes = try await rig.captureBracket(specs) { photo, spec in
                    try bank(photo, spec, device: nil)
                }
            } catch {
                throw SequenceFault(sensor: sensor.rawValue, frameIndex: frames.count + 1,
                                    completed: frames.count, underlying: error)
            }
        }
        return SetShot(frames: frames, bracketRequestSizes: requestSizes)
    }

    static func exposure(from photo: AVCapturePhoto, wb: [Float]) -> FrameRecord.Exposure? {
        guard let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return nil
        }
        return FrameRecord.Exposure(
            shutterSeconds: exif[kCGImagePropertyExifExposureTime as String] as? Double ?? 0,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue ?? 0,
            whiteBalanceGains: wb)
    }

    // MARK: - Bench runs, dispatched rather than performed (#28)
    //
    // These wrappers exist so the bench keeps no opinion about app state. Each
    // gathers what the run needs, awaits it, and applies the outcome here.
    // `BenchModel` never reads or writes anything on this object.

    func runDarkCalibration() async {
        guard let report, report.canCapture else { status = "no usable sensor"; return }
        let sensors = orderedSensors.filter { capability($0)?.isUsable == true }
        guard let set = currentSet else {
            status = "choose a protocol before running a calibration"; return
        }
        busy = true
        defer { busy = false; progress = "" }
        let outcome = await bench.runDarkCalibration(BenchModel.DarkRequest(
            report: report, sensors: sensors, set: set, repeats: bench.darkRepeats))
        // A calibration opens its own session, and adopting it is the caller's
        // decision rather than the run's — which is the whole point of handing
        // back an outcome instead of writing through.
        if let s = outcome.session { session = s }
        status = outcome.status
    }

    #if DEBUG
    func runWhiteBalanceProbe() async {
        guard let session else { status = "open a session first"; return }
        guard let sensor = orderedSensors.first, let cap = capability(sensor), cap.isUsable else {
            status = "no usable sensor selected"; return
        }
        guard let set = currentSet else {
            status = "choose a protocol before running this check"; return
        }
        busy = true
        defer { busy = false; progress = "" }
        stationIndex += 1
        let outcome = await bench.runWhiteBalanceProbe(BenchModel.WhiteBalanceRequest(
            session: session, sensor: sensor, capability: cap, set: set,
            stationIndex: stationIndex, poseIntent: poseIntent,
            run: { specs, sensor, wb, session, station, bracketIndex, firing in
                try await self.shoot(specs, sensor: sensor, wb: wb, session: session,
                                     station: station, bracketIndex: bracketIndex,
                                     firing: firing)
            }))
        if let st = outcome.station { lastStation = st }
        status = outcome.status
    }

    func runZoomProbe() async {
        guard let session else { status = "open a session first"; return }
        guard let sensor = orderedSensors.first else { status = "no sensor selected"; return }
        busy = true
        defer { busy = false }
        status = await bench.runZoomProbe(session: session, sensor: sensor).status
    }
    #endif

    private func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
