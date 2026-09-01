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
        controller.session = session(report: report)
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

    private func session(report: CapabilityReport) -> SessionRecord {
        SessionRecord(sessionId: "test-session", openedAt: Date(timeIntervalSince1970: 10),
                      openedAtUptime: 10, capability: report,
                      availableCapacityBytes: 1_000_000_000)
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
        controller.session = session(report: report)
        return controller
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
        return SetShot(frames: [], bracketRequestSizes: [request.specs.count])
    }
    func stop() { stopCount += 1 }
}

private final class FakeStationPersistence: StationPersisting {
    let report: CapabilityReport
    var hasRoom = true
    var writtenStations: [StationRecord] = []
    var deletedStations: [Int] = []
    init(report: CapabilityReport) { self.report = report }
    func open(capability: CapabilityReport) throws -> SessionRecord {
        SessionRecord(sessionId: "test-session", openedAt: Date(timeIntervalSince1970: 10),
                      openedAtUptime: 10, capability: capability,
                      availableCapacityBytes: 1_000_000_000)
    }
    func hasRoom(forFrames count: Int) -> Bool { hasRoom }
    func writeMotionStream(_ samples: [MotionSample], sessionId: String,
                           station: Int) throws -> String { "motion.jsonl" }
    func writeStation(_ station: StationRecord) throws { writtenStations.append(station) }
    func deleteStationFrames(sessionId: String, station: Int) { deletedStations.append(station) }
}

private final class FakeStationMotion: StationMotionRecording {
    var startCount = 0
    let requestedHz: Double = 100
    func start() { startCount += 1 }
    func stop() {}
    func summary(from start: TimeInterval, to end: TimeInterval) -> MotionSummary? { nil }
    func snapshot() -> [MotionSample] { [] }
    func latestTimestamp() -> TimeInterval? { nil }
}

@MainActor
private final class FakeStationHealth: StationHealthChecking {
    var summary: String { "healthy" }
    func refresh() {}
    func faultIfUnhealthy() -> StationFault? { nil }
}

private enum FakeError: Error { case capture }
