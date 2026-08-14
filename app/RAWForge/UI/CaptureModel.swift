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
    @Published private(set) var report: CapabilityReport?
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

    // Shot-list builder
    @Published var builderSensor: SensorCapability.Sensor = .wide
    @Published var builderProtocolName: String = ""
    @Published var groupShotListBySensor = true

    func addToShotList() {
        guard let p = ProtocolLibrary.load(named: builderProtocolName) else { return }
        var entries = shotList.entries
        entries.append(ShotListEntry(index: entries.count, sensor: builderSensor, captureSet: p))
        shotList.entries = groupShotListBySensor ? ShotList.grouped(entries) : ShotList.authored(entries)
    }

    func clearShotList() {
        shotList = ShotList()
    }

    /// The protocol's demand, authored on device. Never derived from the scene (#8).
    @Published var requestedShutter: Double = 1.0 / 125
    @Published var requestedISO: Float = 100
    @Published var mode: ExecutionMode = .hardwareBracket
    @Published var frameCount: Int = 3
    @Published var stopsPerRung: Double = 1
    @Published var isSweep: Bool = true
    @Published var minimumGap: Double = 0
    /// Optional (#8) — zero means fire as soon as the sensor is configured.
    @Published var dwell: Double = 0
    /// Group-by-sensor is the default; an authored order overrides it (#8).
    @Published var useAuthoredSensorOrder = false
    @Published var authoredSensorOrder: [SensorCapability.Sensor] = []

    /// The protocol in force. Nil means the set is being authored from the
    /// pickers below and has not been named — #8's "no silent default" says a
    /// session is never shot under a protocol nobody chose, and an unnamed set
    /// is a choice too, just an unsaved one.
    @Published var selectedProtocol: CaptureSet?
    @Published var protocolName: String = ""
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

    /// Group by sensor, in the canonical order (#8's default; authored order is
    /// the override, not yet exposed).
    var orderedSensors: [SensorCapability.Sensor] {
        if useAuthoredSensorOrder {
            let authored = authoredSensorOrder.filter { selectedSensors.contains($0) }
            let rest = SensorCapability.Sensor.allCases
                .filter { selectedSensors.contains($0) && !authored.contains($0) }
            return authored + rest
        }
        return SensorCapability.Sensor.allCases.filter { selectedSensors.contains($0) }
    }

    /// Moves a sensor to the end of the authored order, which is how an order is
    /// built by tapping: tap them in the sequence you want them shot.
    func appendToAuthoredOrder(_ s: SensorCapability.Sensor) {
        authoredSensorOrder.removeAll { $0 == s }
        authoredSensorOrder.append(s)
        useAuthoredSensorOrder = true
    }

    var currentSet: CaptureSet {
        if let p = selectedProtocol {
            return CaptureSet(name: p.name, version: p.version, specs: p.specs,
                              generator: p.generator, perSensorEVOffsetStops: evOffsets)
        }
        let base = CaptureSpec(shutterSeconds: requestedShutter, iso: requestedISO)
        let authored: CaptureSet = isSweep
            ? .shutterSweep(base: base, stopsPerRung: stopsPerRung, rungs: frameCount)
            : .repeated(base, count: frameCount)
        return CaptureSet(name: authored.name, version: authored.version, specs: authored.specs,
                          generator: authored.generator, perSensorEVOffsetStops: evOffsets)
    }

    /// #8 keeps ISO a legitimate axis but wants it **warned, not forbidden**:
    /// above roughly 8-9x a sensor's base ISO, Apple applies pure digital gain,
    /// so a ladder climbing in ISO past that point is buying nothing real.
    func isoWarning(for sensor: SensorCapability.Sensor) -> String? {
        guard let cap = capability(sensor), let base = cap.minISO else { return nil }
        let ceiling = base * 8.5
        guard requestedISO > ceiling else { return nil }
        return String(format: "ISO %.0f is past ~8.5x %@'s base of %.0f — beyond that "
                      + "the gain is digital, not analogue. Bracket with shutter.",
                      requestedISO, sensor.rawValue, base)
    }

    func refreshProtocols() { savedProtocols = ProtocolLibrary.all() }

    /// Saving bumps the version (#8's auto-bump), so a set edited mid-shoot is
    /// distinguishable from the one shot ten minutes earlier.
    func saveProtocol() {
        let name = protocolName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { status = "name the protocol before saving"; return }
        do {
            let stored = try ProtocolLibrary.save(currentSet, as: name)
            selectedProtocol = stored
            refreshProtocols()
            status = "saved \(stored.name) v\(stored.version)"
        } catch {
            status = "could not save the protocol — \(error)"
        }
    }

    // MARK: - Probe

    func probe() async {
        guard await requestCamera() else {
            cameraDenied = true
            status = "camera permission denied — no sensor can be probed"
            return
        }
        status = "probing sensors…"
        let result = await Task.detached(priority: .userInitiated) { CapabilityProbe.run() }.value
        report = result
        if let first = result.usableSensors.first { selectedSensors = [first.sensor] }
        status = result.canCapture
            ? "\(result.usableSensors.count) of \(result.sensors.count) sensors deliver Bayer"
            : "no sensor on this device delivers Bayer RAW — capture refused"
    }

    func openSession() {
        guard let report, report.canCapture else { return }
        do {
            // A scene session records which calibration it was shot under and
            // how old it was, so a stale one is visible instead of assumed (#15).
            session = try SessionStore.open(
                capability: report, calibration: SessionStore.latestCalibration())
            stationIndex = 0
            status = "session \(session?.sessionId ?? "?") open"
        } catch {
            status = "session open failed — \(error)"
        }
    }

    // MARK: - Run one station, spanning however many sensors the list names

    func runStation() async {
        guard let session else { status = "open a session first"; return }
        let sensors = orderedSensors.filter { capability($0)?.isUsable == true }
        guard !sensors.isEmpty else { status = "no usable sensor selected"; return }

        busy = true
        defer { busy = false; progress = "" }

        // Storage exhausted is a hard fault (#10), checked before anything
        // fires so the station never half-exists. Worst-case frame size, not
        // average — a station that runs out mid-write is the failure this
        // avoids.
        let plannedFrames = sensors.count * currentSet.specs.count
        guard SessionStore.hasRoom(forFrames: plannedFrames) else {
            let free = SessionStore.availableCapacityBytes() ?? 0
            status = "storage exhausted — \(plannedFrames) frames need up to "
                + "\(plannedFrames * 30) MB, \(free / 1_000_000) MB free. Station not started."
            return
        }

        stationIndex += 1
        let station = stationIndex
        let openedAt = Date()
        let set = currentSet

        var brackets: [BracketRecord] = []
        var swaps: [StationRecord.SwapRecord] = []
        var previousSensor: SensorCapability.Sensor?

        // The IMU runs for the whole station, not per frame: the swap windows
        // matter as much as the exposures, and at ~400 ms a swap is longer than
        // an entire bracket (#7).
        let stationStart = ProcessInfo.processInfo.systemUptime
        motionRecorder.start()

        do {
            for (bracketIndex, sensor) in sensors.enumerated() {
                guard let cap = capability(sensor) else { continue }

                // The swap is timed because #7 left its cost unmeasured, and it
                // is the window in which the pose is held but nothing is shot.
                let swapStart = ProcessInfo.processInfo.systemUptime
                progress = "configuring \(sensor.rawValue)…"
                try rig.configure(sensor)
                rig.startSession()
                let swapEnd = ProcessInfo.processInfo.systemUptime
                swaps.append(StationRecord.SwapRecord(
                    fromSensor: previousSensor?.rawValue,
                    toSensor: sensor.rawValue,
                    durationSeconds: swapEnd - swapStart,
                    motion: motionRecorder.summary(from: swapStart, to: swapEnd)))
                previousSensor = sensor

                // Dwell before the first frame, inside the station but outside
                // any exposure — the tap-induced spike decays here rather than
                // landing in a frame.
                if dwell > 0 {
                    progress = String(format: "%@ dwell %.2fs", sensor.rawValue, dwell)
                    try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                }

                // Rails are per sensor: the same authored set validates
                // differently against 1x and tele, and dropped rungs are
                // recorded per bracket rather than for the station.
                // One definition, rendered per sensor by its EV offset (#8).
                let offset = set.perSensorEVOffsetStops[sensor.rawValue] ?? 0
                let renderedSet = CaptureSet(
                    name: set.name, version: set.version, specs: set.rendered(for: sensor),
                    generator: set.generator, perSensorEVOffsetStops: set.perSensorEVOffsetStops)
                let checked = renderedSet.validated(against: cap)
                guard !checked.kept.isEmpty else {
                    brackets.append(BracketRecord(
                        bracketIndex: bracketIndex + 1, sensor: sensor.rawValue,
                        sensorUniqueID: cap.uniqueID, captureSet: set,
                        renderedSpecs: checked.kept, evOffsetStops: offset,
                        executionMode: mode.rawValue, droppedRungs: checked.dropped,
                        minimumInterFrameGapSeconds: nil, dwellSeconds: dwell > 0 ? dwell : nil,
                        note: nil, frames: []))
                    continue
                }

                let wb = try await rig.lockWhiteBalance()
                let frames = try await shoot(checked.kept, sensor: sensor, wb: wb,
                                             session: session, station: station,
                                             bracketIndex: bracketIndex + 1)
                brackets.append(BracketRecord(
                    bracketIndex: bracketIndex + 1, sensor: sensor.rawValue,
                    sensorUniqueID: cap.uniqueID, captureSet: set,
                    renderedSpecs: checked.kept, evOffsetStops: offset,
                    executionMode: mode.rawValue, droppedRungs: checked.dropped,
                    minimumInterFrameGapSeconds: minimumGap > 0 ? minimumGap : nil,
                    dwellSeconds: dwell > 0 ? dwell : nil, note: nil, frames: frames))
            }
            rig.stopSession()
            motionRecorder.stop()
            let stationEnd = ProcessInfo.processInfo.systemUptime
            let samples = motionRecorder.snapshot()
            let streamFile = samples.isEmpty ? nil
                : try? SessionStore.writeMotionStream(samples, sessionId: session.sessionId, station: station)

            let record = StationRecord(
                stationIndex: station, sessionId: session.sessionId,
                openedAt: openedAt, closedAt: Date(), brackets: brackets, sensorSwaps: swaps,
                motion: MotionSummary.over(samples, from: stationStart, to: stationEnd),
                motionStreamFile: streamFile,
                motionRequestedHz: motionRecorder.requestedHz,
                poseIntent: poseIntent)
            try SessionStore.writeStation(record)
            lastStation = record

            let total = brackets.reduce(0) { $0 + $1.frames.count }
            let swapNote = swaps.dropFirst().map { String(format: "%.0f ms", $0.durationSeconds * 1000) }
                .joined(separator: ", ")
            status = "station \(station): \(total) frames across \(brackets.count) sensor(s)"
                + (swapNote.isEmpty ? "" : " · swaps \(swapNote)")
        } catch {
            rig.stopSession()
            motionRecorder.stop()
            // #10's single rule: a hard fault flags, aborts the station and
            // deletes that station's frames. A station spanning three sensors
            // is still one station, so a fault on tele discards 1x too.
            SessionStore.deleteStationFrames(sessionId: session.sessionId, station: station)
            if let f = error as? SequenceFault {
                status = "station \(station) ABORTED on \(f.sensor) frame \(f.frameIndex) "
                    + "(\(f.completed) done) — \(f.underlying)"
            } else {
                status = "station \(station) ABORTED — \(error)"
            }
        }
    }

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
                throw CaptureRig.RigError.captureFailed("frame \(index): fileDataRepresentation() returned nil")
            }
            let filename = SessionStore.frameFilename(
                sessionId: session.sessionId, station: station,
                bracket: bracketIndex, frame: index, sensor: sensor.rawValue)
            _ = try SessionStore.writeFrame(data, named: filename, sessionId: session.sessionId)

            let witness = DNGMetadata.read(data)
            let clip = ClippingStats.compute(
                from: photo, bayerFormat: rig.bayerFormat,
                activeArea: witness.activeArea,
                blackLevel: witness.blackLevel?.first,
                whiteLevel: witness.whiteLevel?.first)

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

        busy = true
        defer { busy = false; progress = ""; darkProgress = "" }

        let set = currentSet
        let plannedFrames = sensors.count * set.specs.count * darkRepeats
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
            do { try rig.configure(sensor); rig.startSession() }
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
        busy = true
        defer { busy = false; progress = "" }

        stationIndex += 1
        let station = stationIndex
        let openedAt = Date()
        let set = currentSet
        let checked = set.validated(against: cap)
        guard !checked.kept.isEmpty else { status = "every rung is outside the rails"; return }

        let arms: [(String, Float, Float, Float)] = [
            ("warm r3 g1 b1", 3, 1, 1),
            ("cool r1 g1 b3", 1, 1, 3),
        ]
        var brackets: [BracketRecord] = []
        motionRecorder.start()
        do {
            try rig.configure(sensor)
            rig.startSession()
            for (i, arm) in arms.enumerated() {
                progress = "WB probe — \(arm.0)"
                let wb = try await rig.lockWhiteBalanceGains(r: arm.1, g: arm.2, b: arm.3)
                let frames = try await shoot(checked.kept, sensor: sensor, wb: wb,
                                             session: session, station: station, bracketIndex: i + 1)
                brackets.append(BracketRecord(
                    bracketIndex: i + 1, sensor: sensor.rawValue, sensorUniqueID: cap.uniqueID,
                    captureSet: set, renderedSpecs: checked.kept, evOffsetStops: 0,
                    executionMode: mode.rawValue, droppedRungs: checked.dropped,
                    minimumInterFrameGapSeconds: nil, dwellSeconds: nil,
                    note: "item3 " + arm.0, frames: frames))
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
            try rig.configure(sensor)
            rig.startSession()
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
