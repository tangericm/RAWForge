import AVFoundation
import Foundation

/// The runs that characterise the instrument rather than shoot a scene.
///
/// ## Why this is its own object (#28)
///
/// `CaptureModel` had grown to 1,015 lines across itself and its `StationFlow`
/// extension, with 29 `@Published` properties, and the graph put it at nearly
/// double the edge count of the next hub. The ticket's own counter-argument was
/// the right one to test first: *a split that exists only to satisfy a metric
/// buys nothing*. So the seam was chosen by checking what these runs actually
/// reference, not by counting lines.
///
/// They touch **no station-flow state at all** — no `phase`, no `shotList`, no
/// `pendingBrackets`, no `abortStation`. A dark calibration is not a station: it
/// opens its own session, has its own abort unit (the setting, not the run), and
/// never poses the phone at anything.
///
/// ## The shape of the seam
///
/// What they *did* share was session, capability, protocol and status — read
/// and written straight out of `CaptureModel`. Moving the code while keeping
/// those reads would have relocated lines without removing coupling, which is
/// the split the ticket warned against. So every run takes an explicit request
/// with everything it needs and hands back an outcome, and the caller applies
/// that outcome to its own state. Nothing here reaches back.
///
/// ## The shared capture seam
///
/// The white-balance probe and scene stations both need to fire a capture set.
/// #32 put that executor behind `StationCapturing`; the live implementation is
/// `LiveStationCapture`, while this model still receives the operation as a
/// `SetRunner` because a bench run should not own scene lifecycle.
@MainActor
final class BenchModel: ObservableObject {

    /// How a capture set is fired. Injected rather than owned: the bench asks
    /// for a capture but does not own the scene controller that normally does.
    typealias SetRunner = (_ specs: [CaptureSpec],
                           _ sensor: SensorCapability.Sensor,
                           _ wb: (set: [Float], readBack: [Float]),
                           _ session: SessionRecord,
                           _ station: Int,
                           _ bracketIndex: Int,
                           _ firing: ExecutionMode,
                           _ timebase: CaptureTimebase) async throws -> SetShot

    private let rig: CaptureRig
    private let motionRecorder: MotionRecorder

    init(rig: CaptureRig, motionRecorder: MotionRecorder) {
        self.rig = rig
        self.motionRecorder = motionRecorder
    }

    // MARK: - State that belongs to the bench and nowhere else

    @Published var darkRepeats: Int = 8
    @Published private(set) var darkProgress: String = ""
    #if DEBUG
    @Published private(set) var zoomProbe: ZoomProbeResult?
    #endif
    @Published private(set) var running = false

    /// What a run leaves behind for the caller to apply.
    ///
    /// Returned rather than written, so this object never mutates state it does
    /// not own — which is the entire point of the split. `session` is set when
    /// a run opened one of its own (a calibration is its own session type), and
    /// the caller decides whether to adopt it.
    struct Outcome {
        var status: String
        var session: SessionRecord?
        var station: StationRecord?
    }

    // MARK: - Dark calibration (#15)

    /// Everything the run needs, named at the call site rather than read off
    /// another object.
    struct DarkRequest {
        let report: CapabilityReport
        let sensors: [SensorCapability.Sensor]
        let set: CaptureSet
        let repeats: Int
    }

    /// A dark-frame calibration run (#15): the same capture set with the lens
    /// capped, as its own session type, referenced by id from the scene
    /// sessions that depend on it.
    func runDarkCalibration(_ request: DarkRequest) async -> Outcome {
        guard !request.sensors.isEmpty else { return Outcome(status: "no usable sensor selected") }

        running = true
        defer { running = false; darkProgress = "" }
        let captureTimebase = CaptureTimebase(
            segmentID: UUID().uuidString,
            originUptime: ProcessInfo.processInfo.systemUptime)

        let plannedFrames = request.sensors.count * request.set.specs.count * request.repeats
        logInfo(.probe, "dark calibration starting — \(request.sensors.count) sensor(s) × "
                + "\(request.set.specs.count) setting(s) × \(request.repeats) repeat(s) "
                + "= \(plannedFrames) frames")
        guard SessionStore.hasRoom(forFrames: plannedFrames) else {
            return Outcome(status: "storage exhausted — \(plannedFrames) dark frames will not fit")
        }

        let calib: SessionRecord
        do {
            calib = try SessionStore.open(capability: request.report, sessionType: "calibration")
        } catch {
            return Outcome(status: "could not open a calibration session — \(error)")
        }
        let thermalAtOpen = SessionRecord.thermalLabel()

        var settingIndex = 0
        var totalKept = 0, totalRejected = 0

        for sensor in request.sensors {
            guard let cap = request.report.sensors.first(where: { $0.sensor == sensor }) else { continue }
            do { try await rig.configure(sensor); await rig.startSessionAndWait() }
            catch {
                return Outcome(status: "could not open \(sensor.rawValue) — \(error)", session: calib)
            }

            let checked = request.set.validated(against: cap)
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

                    for r in 1...request.repeats {
                        darkProgress = "\(sensor.rawValue) setting \(index) "
                            + "\(spec.shutterLabel) ISO \(Int(spec.iso)) — repeat \(r)/\(request.repeats)"
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
                            // Focus is deliberately unmanaged in a dark run: the
                            // lens is capped, so there is nothing to focus on
                            // and autofocus would only hunt. Nil says "not
                            // managed", which is true, rather than reporting a
                            // lens position that means nothing here.
                            dng: witness, focus: nil, zoomFactor: rig.currentZoomFactor,
                            capturedAtSegmentStartSeconds: captureTimebase.secondsSinceOrigin(
                                ProcessInfo.processInfo.systemUptime),
                            capturedAt: Date(), photoTimestampSeconds:
                                photo.timestamp.isValid ? photo.timestamp.seconds : nil,
                            gapFromPreviousSeconds: nil, clipping: clip, motion: nil,
                            motionNeighbourhood: nil,
                            deliveredAtSegmentStartSeconds: nil,
                            latestMotionAtSegmentStartSeconds: nil))
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
                    requestedRepeats: request.repeats, frames: frames, rejections: rejections,
                    aborted: aborted, abortReason: abortReason),
                    sessionId: calib.sessionId, index: index)

                // The cap being off makes every remaining setting pointless, and
                // a full mirror is minutes of wall clock. Stop on the first
                // setting rather than grinding through 336 refusals.
                if index == 1 && aborted && !rejections.isEmpty {
                    rig.stopSession()
                    return Outcome(
                        status: "cap check failed — \(abortReason ?? "not dark"). "
                              + "Run stopped at setting 1.",
                        session: calib)
                }
            }
            rig.stopSession()
        }

        return Outcome(
            status: "calibration \(calib.sessionId): \(totalKept) frames kept, "
                  + "\(totalRejected) rejected, thermal \(thermalAtOpen) → "
                  + "\(SessionRecord.thermalLabel())",
            session: calib)
    }

    #if DEBUG

    // MARK: - Instrument checks, which never ship

    struct WhiteBalanceRequest {
        let session: SessionRecord
        let sensor: SensorCapability.Sensor
        let capability: SensorCapability
        let set: CaptureSet
        let stationIndex: Int
        let poseIntent: String
        let run: SetRunner
    }

    /// #14 item 3: does a locked white balance reach the Bayer *pixels*, or only
    /// `AsShotNeutral`?
    ///
    /// Shoots the whole capture set twice from one pose, under two deliberately
    /// extreme and opposite gain settings — a small difference would be
    /// indistinguishable from noise in the pixel comparison.
    func runWhiteBalanceProbe(_ request: WhiteBalanceRequest) async -> Outcome {
        running = true
        defer { running = false }

        let openedAt = Date()
        let captureTimebase = CaptureTimebase(
            segmentID: UUID().uuidString,
            originUptime: ProcessInfo.processInfo.systemUptime)
        let checked = request.set.validated(against: request.capability)
        guard !checked.kept.isEmpty else {
            return Outcome(status: "every rung is outside the rails")
        }

        let arms: [(String, Float, Float, Float)] = [
            ("warm r3 g1 b1", 3, 1, 1),
            ("cool r1 g1 b3", 1, 1, 3),
        ]
        var brackets: [BracketRecord] = []
        motionRecorder.start(timebase: captureTimebase)
        do {
            try await rig.configure(request.sensor)
            await rig.startSessionAndWait()
            for (i, arm) in arms.enumerated() {
                darkProgress = "WB probe — \(arm.0)"
                let wb = try await rig.lockWhiteBalanceGains(r: arm.1, g: arm.2, b: arm.3)
                let shot = try await request.run(checked.kept, request.sensor, wb, request.session,
                                                 request.stationIndex, i + 1, request.set.firing,
                                                 captureTimebase)
                brackets.append(BracketRecord(
                    bracketIndex: i + 1, sensor: request.sensor.rawValue,
                    sensorUniqueID: request.capability.uniqueID,
                    captureSet: request.set, renderedSpecs: checked.kept, evOffsetStops: 0,
                    executionMode: request.set.firing.rawValue,
                    bracketRequestSizes: shot.bracketRequestSizes,
                    droppedRungs: checked.dropped,
                    minimumInterFrameGapSeconds: nil,
                    stillnessSettled: nil, stillnessWaitSeconds: nil, motionAtFire: nil,
                    dwellSeconds: nil, note: "item3 " + arm.0, frames: shot.frames))
            }
            rig.stopSession()
            motionRecorder.stop()
            let record = StationRecord(
                stationIndex: request.stationIndex, sessionId: request.session.sessionId,
                openedAt: openedAt, closedAt: Date(), brackets: brackets,
                captureTimebase: captureTimebase,
                motionRequestedHz: motionRecorder.requestedHz,
                poseIntent: request.poseIntent.isEmpty
                    ? "item3 white-balance pixel path" : request.poseIntent)
            try SessionStore.writeStation(record)
            return Outcome(
                status: "WB probe: \(brackets.reduce(0) { $0 + $1.frames.count }) frames, "
                      + "\(arms.count) gain settings — compare pixels off device",
                station: record)
        } catch {
            rig.stopSession(); motionRecorder.stop()
            SessionStore.deleteStationFrames(sessionId: request.session.sessionId,
                                             station: request.stationIndex)
            return Outcome(status: "WB probe ABORTED — \(error)")
        }
    }

    /// #14 item 10, run on the given sensor.
    func runZoomProbe(session: SessionRecord,
                      sensor: SensorCapability.Sensor) async -> Outcome {
        running = true
        defer { running = false }
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
            return Outcome(status: result.verdict)
        } catch {
            return Outcome(status: "zoom probe could not configure \(sensor.rawValue) — \(error)")
        }
    }

    #endif

    private static func exposure(from photo: AVCapturePhoto, wb: [Float]) -> FrameRecord.Exposure? {
        LiveStationCapture.exposure(from: photo, wb: wb)
    }
}
