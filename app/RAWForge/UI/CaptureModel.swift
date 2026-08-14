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

    @Published var mode: ExecutionMode = .hardwareBracket
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
    @Published private(set) var zoomProbe: ZoomProbeResult?

    /// Averaging N frames cuts noise by root-N, and black-level estimation
    /// typically wants 8-16 per setting (#15). Named explicitly rather than
    /// implied.
    @Published var darkRepeats: Int = 8
    @Published private(set) var darkProgress: String = ""

    /// A station is a pose and may span sensors (#7). The shot list names which
    /// ones; pinning to a single sensor is just a list of length one, not a
    /// separate mode.
    @Published var selectedSensors: Set<SensorCapability.Sensor> = [.wide]

    let rig = CaptureRig()
    let motionRecorder = MotionRecorder()
    let health = DeviceHealth()
    var stationIndex = 0

    func capability(_ s: SensorCapability.Sensor) -> SensorCapability? {
        report?.sensors.first { $0.sensor == s }
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
                       session: SessionRecord, station: Int, bracketIndex: Int) async throws -> [FrameRecord] {
        var frames: [FrameRecord] = []
        var previousTimestamp: Double?

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

        switch mode {
        case .sequential:
            var lastFired: TimeInterval?
            for (i, spec) in specs.enumerated() {
                progress = "\(sensor.rawValue) sequential \(i + 1)/\(specs.count) — \(spec.shutterLabel)"
                do {
                    let achieved = try await rig.lockExposure(
                        shutterSeconds: spec.shutterSeconds, iso: spec.iso)
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
                let photos = try await rig.captureBracket(specs)
                for (i, photo) in photos.enumerated() {
                    // No device read-back here: the device is never
                    // reconfigured mid-bracket, so it would report the last
                    // rung for every frame.
                    try bank(photo, i < specs.count ? specs[i] : specs[specs.count - 1], device: nil)
                }
            } catch {
                throw SequenceFault(sensor: sensor.rawValue, frameIndex: frames.count + 1,
                                    completed: frames.count, underlying: error)
            }
        }
        return frames
    }

    private static func exposure(from photo: AVCapturePhoto, wb: [Float]) -> FrameRecord.Exposure? {
        guard let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return nil
        }
        return FrameRecord.Exposure(
            shutterSeconds: exif[kCGImagePropertyExifExposureTime as String] as? Double ?? 0,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue ?? 0,
            whiteBalanceGains: wb)
    }

    /// A dark-frame calibration run (#15): the same capture set with the lens
    /// capped, as its own session type, referenced by id from the scene
    /// sessions that depend on it.
    func runDarkCalibration() async {
        guard let report, report.canCapture else { status = "no usable sensor"; return }
        let sensors = orderedSensors.filter { capability($0)?.isUsable == true }
        guard !sensors.isEmpty else { status = "no usable sensor selected"; return }
        guard let set = currentSet else {
            status = "choose a protocol before running a calibration"; return
        }

        busy = true
        defer { busy = false; progress = ""; darkProgress = "" }

        let plannedFrames = sensors.count * set.specs.count * darkRepeats
        logInfo(.probe, "dark calibration starting — \(sensors.count) sensor(s) × "
                + "\(set.specs.count) setting(s) × \(darkRepeats) repeat(s) = \(plannedFrames) frames")
        guard SessionStore.hasRoom(forFrames: plannedFrames) else {
            status = "storage exhausted — \(plannedFrames) dark frames will not fit"
            return
        }

        let calib: SessionRecord
        do {
            calib = try SessionStore.open(capability: report, sessionType: "calibration")
        } catch {
            status = "could not open a calibration session — \(error)"; return
        }
        session = calib
        let thermalAtOpen = SessionRecord.thermalLabel()

        var settingIndex = 0
        var totalKept = 0, totalRejected = 0

        for sensor in sensors {
            guard let cap = capability(sensor) else { continue }
            do { try await rig.configure(sensor); await rig.startSessionAndWait() }
            catch { status = "could not open \(sensor.rawValue) — \(error)"; continue }

            let checked = set.validated(against: cap)
            for spec in checked.kept {
                settingIndex += 1
                let index = settingIndex
                var frames: [FrameRecord] = []
                var rejections: [DarkFrameRejection] = []
                var aborted = false
                var abortReason: String?

                do {
                    _ = try await rig.lockWhiteBalance()
                    let achieved = try await rig.lockExposure(
                        shutterSeconds: spec.shutterSeconds, iso: spec.iso)

                    for r in 1...darkRepeats {
                        darkProgress = "\(sensor.rawValue) setting \(index) "
                            + "\(spec.shutterLabel) ISO \(Int(spec.iso)) — repeat \(r)/\(darkRepeats)"
                        let photo = try await rig.captureSingle()
                        guard let data = photo.fileDataRepresentation() else {
                            throw CaptureRig.RigError.captureFailed("no DNG data")
                        }
                        let witness = DNGMetadata.read(data)
                        let clip = ClippingStats.compute(
                            from: photo, bayerFormat: rig.bayerFormat,
                            activeArea: witness.activeArea,
                            blackLevel: witness.blackLevel?.first,
                            whiteLevel: witness.whiteLevel?.first)
                        let verdict = DarkFrameValidation.check(clip)

                        // Reject, do not warn (#15). A frame that is not dark is
                        // not written as a dark frame — but the refusal is.
                        guard verdict?.passed == true else {
                            rejections.append(DarkFrameRejection(
                                sensor: sensor.rawValue, shutterSeconds: spec.shutterSeconds,
                                iso: spec.iso, repeatIndex: r, validation: verdict,
                                note: verdict?.failureReason
                                    ?? "could not validate — no clipping statistics available"))
                            aborted = true
                            abortReason = verdict?.failureReason ?? "validation unavailable"
                            break
                        }

                        let name = SessionStore.darkFrameFilename(
                            sessionId: calib.sessionId, setting: index,
                            repeatIndex: r, sensor: sensor.rawValue)
                        _ = try SessionStore.writeFrame(data, named: name, sessionId: calib.sessionId)
                        frames.append(FrameRecord(
                            frameIndex: r, filename: name, sensor: sensor.rawValue,
                            requested: FrameRecord.Exposure(
                                shutterSeconds: spec.shutterSeconds, iso: spec.iso, whiteBalanceGains: nil),
                            deviceAchieved: achieved,
                            photoAchieved: Self.exposure(from: photo, wb: []),
                            dng: witness, zoomFactor: rig.currentZoomFactor,
                            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
                            capturedAt: Date(), photoTimestampSeconds:
                                photo.timestamp.isValid ? photo.timestamp.seconds : nil,
                            gapFromPreviousSeconds: nil, clipping: clip, motion: nil,
                            motionNeighbourhood: nil, uptimeAtDelivery: nil, latestMotionTimestamp: nil))
                    }
                } catch {
                    aborted = true
                    abortReason = "\(error)"
                }

                if aborted {
                    // The abort unit is this setting, not the run (#15).
                    SessionStore.deleteDarkSettingFrames(sessionId: calib.sessionId, setting: index)
                    frames = []
                }
                totalKept += frames.count
                totalRejected += rejections.count
                try? SessionStore.writeDarkSetting(DarkSettingRecord(
                    sensor: sensor.rawValue, shutterSeconds: spec.shutterSeconds, iso: spec.iso,
                    requestedRepeats: darkRepeats, frames: frames, rejections: rejections,
                    aborted: aborted, abortReason: abortReason),
                    sessionId: calib.sessionId, index: index)

                // The cap being off makes every remaining setting pointless, and
                // a full mirror is minutes of wall clock. Stop on the first
                // setting rather than grinding through 336 refusals.
                if index == 1 && aborted && !rejections.isEmpty {
                    rig.stopSession()
                    status = "cap check failed — \(abortReason ?? "not dark"). Run stopped at setting 1."
                    return
                }
            }
            rig.stopSession()
        }

        status = "calibration \(calib.sessionId): \(totalKept) frames kept, "
            + "\(totalRejected) rejected, thermal \(thermalAtOpen) → \(SessionRecord.thermalLabel())"
    }

    /// #14 item 3: does a locked white balance reach the Bayer *pixels*, or only
    /// `AsShotNeutral`?
    ///
    /// Shoots the whole capture set twice from one pose, under two deliberately
    /// extreme and opposite gain settings, as two brackets of one station. The
    /// set is a ladder rather than a single frame on purpose: with no
    /// viewfinder there is no way to know on device which exposure is properly
    /// exposed, and a pair compared at a near-black exposure would read as
    /// identical whatever the white balance did. Choosing the usable rung is
    /// left to the workstation, which is where judgement belongs (#8).
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
        let station = stationIndex
        let openedAt = Date()
        let checked = set.validated(against: cap)
        guard !checked.kept.isEmpty else { status = "every rung is outside the rails"; return }

        let arms: [(String, Float, Float, Float)] = [
            ("warm r3 g1 b1", 3, 1, 1),
            ("cool r1 g1 b3", 1, 1, 3),
        ]
        var brackets: [BracketRecord] = []
        motionRecorder.start()
        do {
            try await rig.configure(sensor)
            await rig.startSessionAndWait()
            for (i, arm) in arms.enumerated() {
                progress = "WB probe — \(arm.0)"
                let wb = try await rig.lockWhiteBalanceGains(r: arm.1, g: arm.2, b: arm.3)
                let frames = try await shoot(checked.kept, sensor: sensor, wb: wb,
                                             session: session, station: station, bracketIndex: i + 1)
                brackets.append(BracketRecord(
                    bracketIndex: i + 1, sensor: sensor.rawValue, sensorUniqueID: cap.uniqueID,
                    captureSet: set, renderedSpecs: checked.kept, evOffsetStops: 0,
                    executionMode: mode.rawValue, droppedRungs: checked.dropped,
                    minimumInterFrameGapSeconds: nil,
                    stillnessSettled: nil, stillnessWaitSeconds: nil, motionAtFire: nil,
                    dwellSeconds: nil, note: "item3 " + arm.0, frames: frames))
            }
            rig.stopSession()
            motionRecorder.stop()
            let record = StationRecord(
                stationIndex: station, sessionId: session.sessionId, openedAt: openedAt,
                closedAt: Date(), brackets: brackets,
                motionRequestedHz: motionRecorder.requestedHz,
                poseIntent: poseIntent.isEmpty ? "item3 white-balance pixel path" : poseIntent)
            try SessionStore.writeStation(record)
            lastStation = record
            status = "WB probe: \(brackets.reduce(0){ $0 + $1.frames.count }) frames, "
                + "\(arms.count) gain settings — compare pixels off device"
        } catch {
            rig.stopSession(); motionRecorder.stop()
            SessionStore.deleteStationFrames(sessionId: session.sessionId, station: station)
            status = "WB probe ABORTED — \(error)"
        }
    }

    /// #14 item 10, run on the currently selected sensor.
    func runZoomProbe() async {
        guard let session else { status = "open a session first"; return }
        guard let sensor = orderedSensors.first else { status = "no sensor selected"; return }
        busy = true
        defer { busy = false }
        do {
            try await rig.configure(sensor)
            await rig.startSessionAndWait()
            defer { rig.stopSession() }
            // Each stage is flushed to disk as it happens, so a crash inside
            // AVFoundation still leaves a record of how far the probe got.
            var stages: [String] = []
            let result = await rig.probeZoomEnforcement { stageName in
                stages.append(stageName)
                try? SessionStore.writeProbe(stages, named: "zoom-probe-stages.json",
                                             sessionId: session.sessionId)
            }
            zoomProbe = result
            try? SessionStore.writeProbe(result, named: "zoom-probe-\(sensor.rawValue).json",
                                         sessionId: session.sessionId)
            status = result.verdict
        } catch {
            status = "zoom probe could not configure \(sensor.rawValue) — \(error)"
        }
    }

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
