import Foundation
import XCTest
@testable import RAWForge

/// Station behaviour through the same interface the capture screen uses.
/// AVFoundation, CoreMotion and Documents are adapters at the controller's
/// internal seams; none is required to prove the lifecycle itself.
@MainActor
final class StationControllerTests: XCTestCase {

    func testDeclaringAStationOwnsTheWholeLifecycleState() {
        let report = capabilityReport()
        let motion = FakeStationMotion()
        let controller = StationController(
            capture: FakeStationCapture(),
            persistence: FakeStationPersistence(report: report),
            motion: motion,
            health: FakeStationHealth(),
            clock: .immediate)
        controller.report = report
        controller.openSession()
        controller.shotList.entries = [entry(.wide, frames: 3)]
        controller.phase = .sessionOpen

        XCTAssertEqual(controller.primaryAction, .declareStation)
        controller.declareStation()

        XCTAssertEqual(controller.phase, .stationOpen)
        XCTAssertEqual(controller.stationIndex, 1)
        XCTAssertEqual(controller.shotList.cursor, 0)
        XCTAssertNotNil(controller.stationEstimateSeconds)
        XCTAssertEqual(motion.startCount, 1)
    }

    func testOneSetRunsThroughTheAdapterAndReturnsToTheStation() async {
        let report = capabilityReport()
        let capture = FakeStationCapture()
        let controller = makeController(report: report, capture: capture)
        controller.shotList.entries = [entry(.wide, frames: 3)]
        controller.phase = .sessionOpen
        controller.declareStation()

        await controller.beginNextSet()

        XCTAssertEqual(capture.configuredSensors, [.wide])
        XCTAssertEqual(capture.requests.map(\.specs.count), [3])
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.framingSensors, [.wide],
                       "the preview must resume after the capture session releases the rig")
        XCTAssertEqual(controller.shotList.cursor, 1)
        XCTAssertEqual(controller.pendingBrackets.count, 1)
        XCTAssertEqual(controller.phase, .stationOpen)
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.primaryAction, .closeStation)
    }

    func testReturningToASensorRestoresOnlyThatSensorsOwnFocus() async {
        let report = capabilityReport(sensors: [.wide, .telephoto])
        let capture = FakeStationCapture()
        let controller = makeController(report: report, capture: capture)
        controller.groupShotListBySensor = false
        controller.shotList.entries = [
            entry(.wide, frames: 1), entry(.telephoto, frames: 1), entry(.wide, frames: 1),
        ]
        controller.phase = .sessionOpen
        controller.declareStation()

        await controller.beginNextSet()
        await controller.beginNextSet()
        await controller.beginNextSet()

        XCTAssertNil(capture.focusResolutions[0].restore)
        XCTAssertNil(capture.focusResolutions[1].restore,
                     "a lens position must never cross a sensor boundary")
        XCTAssertEqual(capture.focusResolutions[2].restore, 0.5,
                       "returning to the same actuator should restore its station lock")
    }

    func testCaptureFailureAbortsAndDeletesOnlyTheOpenStation() async {
        let report = capabilityReport()
        let capture = FakeStationCapture()
        capture.captureError = FakeError.capture
        let persistence = FakeStationPersistence(report: report)
        let controller = makeController(report: report, capture: capture,
                                        persistence: persistence)
        controller.focusPlan[.wide] = .manual(lensPosition: 0.4)
        controller.shotList.entries = [entry(.wide, frames: 2)]
        controller.phase = .sessionOpen
        controller.declareStation()

        await controller.beginNextSet()

        XCTAssertEqual(controller.lastFault, .captureError)
        XCTAssertEqual(controller.phase, .sessionOpen)
        XCTAssertTrue(controller.pendingBrackets.isEmpty)
        XCTAssertEqual(persistence.deletedStations, [1])
        XCTAssertTrue(controller.status.contains("ABORTED"))
        XCTAssertEqual(controller.focusPlan, FocusPlan())
    }

    func testClosingBanksOneWholeStationAndResetsPoseState() async {
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let controller = makeController(report: report, persistence: persistence)
        controller.poseIntent = "tripod-rigid"
        controller.focusPlan[.wide] = .manual(lensPosition: 0.4)
        controller.shotList.entries = [entry(.wide, frames: 1)]
        controller.phase = .sessionOpen
        controller.declareStation()
        await controller.beginNextSet()

        controller.closeStation()

        XCTAssertEqual(persistence.writtenStations.count, 1)
        XCTAssertEqual(persistence.writtenStations.first?.poseIntent, "tripod-rigid")
        XCTAssertEqual(controller.lastStation, persistence.writtenStations.first)
        XCTAssertEqual(controller.phase, .sessionOpen)
        XCTAssertTrue(controller.pendingBrackets.isEmpty)
        XCTAssertEqual(controller.focusPlan, FocusPlan(),
                       "a focus decision belongs to the pose that just closed")
    }

    func testStartingFlowAgainCannotStrandAnOpenStation() {
        let report = capabilityReport()
        let controller = makeController(report: report)
        controller.shotList.entries = [entry(.wide, frames: 1)]
        controller.phase = .stationOpen
        controller.shotList.cursor = 1

        controller.startFlow()

        XCTAssertEqual(controller.phase, .stationOpen)
        XCTAssertEqual(controller.primaryAction, .closeStation)
    }

    func testBankedFramesAndMotionUseCaptureSegmentRelativeTime() async throws {
        let report = capabilityReport()
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        let persistence = FakeStationPersistence(report: report)
        let motion = FakeStationMotion()
        motion.emitsSamplesAndSummaries = true
        let controller = StationController(
            capture: capture,
            persistence: persistence,
            motion: motion,
            health: FakeStationHealth(),
            clock: testClock(startingUptime: 1_000))
        controller.report = report
        controller.openSession()
        controller.startFlow()
        controller.addToShotList(
            .repeated(.init(shutterSeconds: 0.01, iso: 100), count: 1),
            sensor: .wide)
        controller.declareStation()

        await controller.beginNextSet()
        controller.closeStation()

        let station = try XCTUnwrap(persistence.writtenStation)
        let frame = try XCTUnwrap(station.brackets.first?.frames.first)
        XCTAssertLessThan(frame.capturedAtSegmentStartSeconds, 10)
        XCTAssertLessThan(station.motion?.windowEnd ?? 100, 10)
        XCTAssertLessThan(station.sensorSwaps.first?.motion?.windowEnd ?? 100, 10)
        XCTAssertLessThan(station.brackets.first?.motionAtFire?.windowEnd ?? 100, 10)
        XCTAssertEqual(station.captureSegmentID, capture.requests.first?.timebase.segmentID)
        XCTAssertEqual(station.monotonicTimebase, CaptureTimebase.persistedName)
    }

    // MARK: - Fixtures

    private func capabilityReport(
        sensors: [SensorCapability.Sensor] = [.wide]
    ) -> CapabilityReport {
        CapabilityReport(device: .current(), sensors: sensors.map(usableSensor))
    }

    private func usableSensor(_ sensor: SensorCapability.Sensor) -> SensorCapability {
        SensorCapability(
            sensor: sensor, localizedName: "test", uniqueID: "uid-\(sensor.rawValue)",
            modelID: "model", bayerFormat: 0x62676734, allRawFormats: ["'bgg4'"],
            rawFormatsRequiredRunningSession: false, exclusionReason: nil,
            supportsCustomExposure: true, supportsWhiteBalanceCustomGainLock: true,
            supportsLockedFocus: true, supportsCustomLensPosition: true,
            supportsFocusPointOfInterest: true, minimumFocusDistanceMillimetres: 120,
            horizontalFieldOfViewDegrees: 69, maxBracketedCapturePhotoCount: 8,
            maxWhiteBalanceGain: 4, minAvailableVideoZoomFactor: 1,
            minISO: 50, maxISO: 6400,
            minExposureSeconds: 1.0 / 66_000, maxExposureSeconds: 1)
    }

    private func entry(_ sensor: SensorCapability.Sensor, frames: Int) -> ShotListEntry {
        ShotListEntry(index: 0, sensor: sensor,
                      captureSet: .repeated(
                        CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
                        count: frames, name: "test"))
    }

    private func makeController(
        report: CapabilityReport,
        capture: FakeStationCapture? = nil,
        persistence: FakeStationPersistence? = nil
    ) -> StationController {
        let controller = StationController(
            capture: capture ?? FakeStationCapture(),
            persistence: persistence ?? FakeStationPersistence(report: report),
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        controller.report = report
        controller.openSession()
        return controller
    }

    private func testClock(startingUptime: TimeInterval) -> StationClock {
        let box = TestClockBox(uptime: startingUptime)
        return StationClock(
            date: { box.date },
            uptime: {
                defer { box.uptime += 0.05 }
                return box.uptime
            },
            sleep: { seconds in
                box.uptime += max(0, seconds)
                box.date = box.date.addingTimeInterval(max(0, seconds))
            })
    }
}

private final class TestClockBox {
    var uptime: TimeInterval
    var date: Date

    init(uptime: TimeInterval) {
        self.uptime = uptime
        date = Date(timeIntervalSince1970: uptime)
    }
}

@MainActor
private final class FakeStationCapture: StationCapturing {
    var configuredSensors: [SensorCapability.Sensor] = []
    var framingSensors: [SensorCapability.Sensor] = []
    var focusResolutions: [FocusResolution] = []
    var requests: [StationCaptureRequest] = []
    var stopCount = 0
    var captureError: Error?
    var emitsFrame = false

    func prepareForFraming(_ sensor: SensorCapability.Sensor) {
        framingSensors.append(sensor)
    }
    func configure(_ sensor: SensorCapability.Sensor) async throws {
        configuredSensors.append(sensor)
    }
    func lockWhiteBalance() async throws -> StationWhiteBalance {
        StationWhiteBalance(set: [1, 1, 1, 1], readBack: [1, 1, 1, 1])
    }
    func applyFocus(_ resolution: FocusResolution) async -> FrameRecord.Focus {
        focusResolutions.append(resolution)
        return FrameRecord.Focus(
            intent: "automatic", acquisition: "autofocused", mode: "locked",
            lensPosition: 0.5, pointOfInterest: nil, pointMappedFromSensor: nil,
            converged: true, acquisitionSeconds: 0.1,
            minimumFocusDistanceMillimetres: 120, note: nil)
    }
    func capture(_ request: StationCaptureRequest,
                 progress: @escaping (String) -> Void) async throws -> SetShot {
        requests.append(request)
        if let captureError { throw captureError }
        let frames = emitsFrame ? [frameFixture(request: request)] : []
        return SetShot(frames: frames, bracketRequestSizes: [request.specs.count])
    }
    func stop() { stopCount += 1 }
}

private final class FakeStationPersistence: StationPersisting {
    let report: CapabilityReport
    var hasRoom = true
    var writtenStations: [StationRecord] = []
    var deletedStations: [Int] = []
    var writtenStation: StationRecord? { writtenStations.last }
    init(report: CapabilityReport) { self.report = report }
    func open(capability: CapabilityReport) throws -> SessionRecord {
        SessionRecord(sessionId: "test-session", openedAt: Date(timeIntervalSince1970: 10),
                      capability: capability, availableCapacityBytes: 1_000_000_000)
    }
    func hasRoom(forFrames count: Int) -> Bool { hasRoom }
    func writeMotionStream(_ samples: [MotionSample], sessionId: String,
                           station: Int) throws -> String { "motion.jsonl" }
    func writeStation(_ station: StationRecord) throws { writtenStations.append(station) }
    func deleteStationFrames(sessionId: String, station: Int) { deletedStations.append(station) }
}

private final class FakeStationMotion: StationMotionRecording {
    var startCount = 0
    var emitsSamplesAndSummaries = false
    private var timebase: CaptureTimebase?
    let requestedHz: Double = 100
    func start(timebase: CaptureTimebase) {
        startCount += 1
        self.timebase = timebase
    }
    func stop() {}
    func summary(from start: TimeInterval, to end: TimeInterval) -> MotionSummary? {
        guard emitsSamplesAndSummaries else { return nil }
        return motionSummaryFixture(windowStart: start, windowEnd: end)
    }
    func snapshot() -> [MotionSample] {
        guard emitsSamplesAndSummaries, timebase != nil else { return [] }
        return [
            MotionSample(secondsSinceSegmentStart: 0.1,
                         gx: 0.01, gy: 0, gz: 0, ax: 0.1, ay: 0, az: 0),
            MotionSample(secondsSinceSegmentStart: 0.2,
                         gx: 0.01, gy: 0, gz: 0, ax: 0.1, ay: 0, az: 0),
        ]
    }
    func latestTimestamp() -> TimeInterval? {
        emitsSamplesAndSummaries ? 0.2 : nil
    }
}

@MainActor
private final class FakeStationHealth: StationHealthChecking {
    var summary: String { "healthy" }
    func refresh() {}
    func faultIfUnhealthy() -> StationFault? { nil }
}

private enum FakeError: Error { case capture }

private func frameFixture(request: StationCaptureRequest) -> FrameRecord {
    FrameRecord(
        frameIndex: 1,
        filename: "frame.dng",
        sensor: request.sensor.rawValue,
        requested: FrameRecord.Exposure(
            shutterSeconds: request.specs[0].shutterSeconds,
            iso: request.specs[0].iso,
            whiteBalanceGains: request.whiteBalance.set),
        deviceAchieved: nil,
        photoAchieved: nil,
        dng: FrameRecord.DNGWitness(
            exposureTimeSeconds: nil, iso: nil, asShotNeutral: nil,
            blackLevel: nil, whiteLevel: nil, cfaPattern: nil, activeArea: nil,
            uniqueCameraModel: nil, localizedCameraModel: nil,
            noiseReductionAppliedCoerced: nil, noiseReductionApplied: nil,
            noiseProfile: nil, dateTimeOriginal: nil, subsecTimeOriginal: nil,
            storedImageWidth: nil, imageWidth: nil, imageHeight: nil),
        focus: request.focus,
        zoomFactor: 1,
        capturedAtSegmentStartSeconds: request.timebase.secondsSinceOrigin(
            request.timebase.originUptime + 2.5),
        capturedAt: Date(timeIntervalSince1970: 10),
        photoTimestampSeconds: nil,
        gapFromPreviousSeconds: nil,
        clipping: nil,
        motion: nil,
        motionNeighbourhood: nil,
        deliveredAtSegmentStartSeconds: 2.6,
        latestMotionAtSegmentStartSeconds: 2.55)
}

private func motionSummaryFixture(
    windowStart: TimeInterval,
    windowEnd: TimeInterval
) -> MotionSummary {
    MotionSummary(
        windowStart: windowStart,
        windowEnd: windowEnd,
        sampleCount: 10,
        effectiveHz: 100,
        worstGapSeconds: 0.01,
        gyroP50: 0.01,
        gyroP90: 0.01,
        gyroP99: 0.01,
        gyroMax: 0.01,
        accelP50: 0.1,
        accelP90: 0.1,
        accelP99: 0.1,
        accelMax: 0.1)
}
