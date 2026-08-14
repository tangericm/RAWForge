import XCTest
@testable import RAWForge

/// The rules that decide what the operator is allowed to do, and when.
///
/// These are the parts of the station flow that can be exercised without a
/// camera: which action the one button offers, and whether bringing the screen
/// back up is safe while a station is in flight. Firing a set still needs
/// hardware — but the decisions *around* firing are where a mistake silently
/// costs a station, so they are worth pinning down.
@MainActor
final class FlowStateTests: XCTestCase {

    // MARK: - Fixtures

    private func usableSensor(_ s: SensorCapability.Sensor) -> SensorCapability {
        SensorCapability(
            sensor: s, localizedName: "test", uniqueID: "uid-\(s.rawValue)", modelID: "model",
            bayerFormat: 0x62676734 /* 'bgg4' */, allRawFormats: ["'bgg4'"],
            rawFormatsRequiredRunningSession: false, exclusionReason: nil,
            supportsCustomExposure: true, supportsWhiteBalanceCustomGainLock: true,
            supportsLockedFocus: true, supportsCustomLensPosition: true,
            supportsFocusPointOfInterest: true,
            minimumFocusDistanceMillimetres: 120, horizontalFieldOfViewDegrees: 69,
            maxBracketedCapturePhotoCount: 8, maxWhiteBalanceGain: 4,
            minAvailableVideoZoomFactor: 1.0,
            minISO: 50, maxISO: 6400,
            minExposureSeconds: 1.0 / 66_000, maxExposureSeconds: 1.0)
    }

    private func model(canCapture: Bool = true) -> CaptureModel {
        let m = CaptureModel()
        m.report = CapabilityReport(
            device: DeviceIdentity.current(),
            sensors: canCapture
                ? [usableSensor(.wide), usableSensor(.telephoto)]
                : [.absent(.wide), .absent(.ultraWide), .absent(.telephoto)])
        return m
    }

    private func entry(_ sensor: SensorCapability.Sensor, frames: Int) -> ShotListEntry {
        ShotListEntry(
            index: 0, sensor: sensor,
            captureSet: .repeated(CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
                                  count: frames, name: "test"))
    }

    // MARK: - What the one button offers

    func testWithoutABayerSensorNothingIsOffered() {
        let m = model(canCapture: false)
        guard case .blocked = m.primaryAction else {
            return XCTFail("a device with no Bayer sensor must offer no action")
        }
        XCTAssertFalse(m.primaryAction.isEnabled)
    }

    func testOpensASessionFirst() {
        let m = model()
        m.phase = .noSession
        XCTAssertEqual(m.primaryAction, .openSession)
    }

    /// A station with nothing to shoot is not a station, so declaring one is
    /// refused rather than allowed and then found to be empty.
    func testAStationCannotBeDeclaredWithAnEmptyShotList() {
        let m = model()
        m.phase = .sessionOpen
        guard case .blocked = m.primaryAction else {
            return XCTFail("an empty shot list must block declaring a station")
        }
    }

    func testDeclaresAStationOnceTheListHasSomethingInIt() {
        let m = model()
        m.phase = .sessionOpen
        m.shotList.entries = [entry(.wide, frames: 3)]
        XCTAssertEqual(m.primaryAction, .declareStation)
    }

    func testWalksTheShotListOneSetAtATime() {
        let m = model()
        m.phase = .stationOpen
        m.shotList.entries = [entry(.wide, frames: 3), entry(.telephoto, frames: 3)]
        m.shotList.cursor = 0
        XCTAssertEqual(m.primaryAction, .beginSet(index: 1, total: 2))
        m.shotList.cursor = 1
        XCTAssertEqual(m.primaryAction, .beginSet(index: 2, total: 2))
    }

    /// Closing only becomes available once the whole list is done — there is no
    /// partial-completion state because there is no way to leave one.
    func testClosingIsOnlyOfferedOnceTheListIsFinished() {
        let m = model()
        m.phase = .stationOpen
        m.shotList.entries = [entry(.wide, frames: 3)]
        m.shotList.cursor = 0
        XCTAssertNotEqual(m.primaryAction, .closeStation)
        m.shotList.cursor = 1
        XCTAssertEqual(m.primaryAction, .closeStation)
        XCTAssertTrue(m.primaryAction.isTerminal)
    }

    func testNothingIsOfferedWhileAWaitIsRunning() {
        let m = model()
        m.shotList.entries = [entry(.wide, frames: 3)]
        for phase in [StationPhase.swapping, .stilling, .settling, .capturing] {
            m.phase = phase
            XCTAssertFalse(m.primaryAction.isEnabled,
                           "\(phase.rawValue) must not offer an action")
            XCTAssertEqual(m.primaryAction.title, phase.title,
                           "a blocked button should say what is being waited on")
        }
    }

    // MARK: - Returning to the screen

    /// The regression this exists for: the capture screen calls `startFlow()`
    /// from `onAppear`, which fires again every time the tab is returned to —
    /// and checking the console mid-station is exactly what the console is for.
    /// Resetting the phase there would strand an open station's buffered
    /// brackets, leaving frames in memory belonging to a station that could no
    /// longer be closed *or* aborted.
    func testReturningToTheScreenDoesNotStrandAnOpenStation() {
        let m = model()
        m.session = try? SessionStore.open(capability: m.report!)
        m.phase = .stationOpen
        m.shotList.entries = [entry(.wide, frames: 3)]
        m.shotList.cursor = 1

        m.startFlow()

        XCTAssertEqual(m.phase, .stationOpen, "an in-flight station must survive a tab switch")
        XCTAssertEqual(m.primaryAction, .closeStation, "and must still be closeable")
        if let id = m.session?.sessionId { try? SessionStore.deleteSession(id) }
    }

    func testStartingWithNoSessionLandsOnTheNoSessionPhase() {
        let m = model()
        m.session = nil
        m.phase = .capturing          // stale state from a previous run
        m.startFlow()
        // Still in a station, so it is left alone rather than reset.
        XCTAssertEqual(m.phase, .capturing)

        m.phase = .sessionOpen
        m.startFlow()
        XCTAssertEqual(m.phase, .noSession)
    }

    // MARK: - The shot list itself

    func testGroupingBySensorSurvivesARegroup() {
        let m = model()
        m.groupShotListBySensor = true
        m.shotList.entries = ShotList.grouped([
            entry(.wide, frames: 1), entry(.telephoto, frames: 1), entry(.wide, frames: 2),
        ])
        m.regroupShotList()
        XCTAssertEqual(m.shotList.entries.map(\.sensor), [.wide, .wide, .telephoto])
        XCTAssertEqual(m.shotList.entries.map(\.index), [0, 1, 2],
                       "indices are renumbered so entry ids stay unique")
    }

    /// Moving an entry *is* authoring an order, so it turns grouping off rather
    /// than silently undoing the move on the next regroup.
    func testReorderingTurnsGroupingOff() {
        let m = model()
        m.groupShotListBySensor = true
        m.shotList.entries = [entry(.wide, frames: 1), entry(.telephoto, frames: 1)]
        m.moveInShotList(from: IndexSet(integer: 1), to: 0)
        XCTAssertFalse(m.groupShotListBySensor)
        XCTAssertEqual(m.shotList.entries.map(\.sensor), [.telephoto, .wide])
    }
}
