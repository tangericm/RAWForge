import Foundation
import XCTest
@testable import RAWForge

/// Station behaviour through the same interface the capture screen uses.
/// AVFoundation, CoreMotion and Documents are adapters at the controller's
/// internal seams; none is required to prove the lifecycle itself.
@MainActor
final class StationControllerTests: XCTestCase {

    func testStopDuringDwellReturnsBeforeTheUnexposedWaitElapses() async throws {
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let capture = FakeStationCapture()
        let sleeping = expectation(description: "entered authored dwell")
        let finished = expectation(description: "Stop returned before dwell ended")
        let immediate = StationClock.immediate
        let clock = StationClock(date: immediate.date, uptime: immediate.uptime, sleep: { seconds in
            if seconds == 2 {
                sleeping.fulfill()
                await StationClock.live.sleep(seconds)
            }
        })
        let controller = StationController(capture: capture, persistence: persistence,
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: clock)
        controller.report = report
        let recipe = recipeFixture(steps: [try .validated(sensor: .wide,
            captureSet: recipeSet(), dwellSeconds: 2)])
        let task = Task { @MainActor in
            let outcome = await controller.captureTake(recipe: RecipeSnapshot(recipe))
            finished.fulfill()
            return outcome
        }
        await fulfillment(of: [sleeping], timeout: 2)
        controller.requestStop()
        controller.requestStop() // Repeated taps must remain harmless.
        await fulfillment(of: [finished], timeout: 0.3)
        let outcome = await task.value
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(capture.requests.isEmpty)
        XCTAssertTrue(persistence.writtenStations.isEmpty)
        XCTAssertFalse(controller.busy)
        capture.emitsFrame = true
        let next = recipeFixture(steps: [try .validated(sensor: .wide, captureSet: recipeSet())])
        let nextOutcome = await controller.captureTake(recipe: RecipeSnapshot(next))
        guard case .completed = nextOutcome else { return XCTFail("\(nextOutcome)") }
        XCTAssertEqual(capture.requests.count, 1, "Stop must not leak into the next Take")
    }

    func testUncancelledDwellFinishesBeforeAnyCameraRequest() async throws {
        let report = capabilityReport()
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        let immediate = StationClock.immediate
        var dwellFinished = false
        let clock = StationClock(date: immediate.date, uptime: immediate.uptime, sleep: { seconds in
            if seconds == 0.08 {
                XCTAssertTrue(capture.requests.isEmpty)
                let start = ProcessInfo.processInfo.systemUptime
                await StationClock.live.sleep(seconds)
                XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.08)
                XCTAssertTrue(capture.requests.isEmpty)
                dwellFinished = true
            }
        })
        let controller = StationController(capture: capture,
            persistence: FakeStationPersistence(report: report), motion: FakeStationMotion(),
            health: FakeStationHealth(), clock: clock)
        controller.report = report
        let recipe = recipeFixture(steps: [try .validated(sensor: .wide,
            captureSet: recipeSet(), dwellSeconds: 0.08)])
        let outcome = await controller.captureTake(recipe: RecipeSnapshot(recipe))
        guard case .completed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(dwellFinished)
        XCTAssertEqual(capture.requests.count, 1)
    }

    func testLegacyInvalidTimingIsRejectedBeforeConfiguringCamera() async {
        for invalidWait in [true, false] {
            let report = capabilityReport()
            let capture = FakeStationCapture()
            let controller = makeController(report: report, capture: capture)
            controller.shotList.entries = [ShotListEntry(index: 0, sensor: .wide,
                captureSet: recipeSet(firing: .sequential))]
            controller.dwell = invalidWait ? 20_000_000_000 : 0
            controller.minimumGap = invalidWait ? 0 : 20_000_000_000
            controller.phase = .sessionOpen
            controller.declareStation()
            await controller.beginNextSet()
            XCTAssertTrue(capture.configuredSensors.isEmpty)
            XCTAssertTrue(capture.requests.isEmpty)
            XCTAssertEqual(controller.lastFault, .captureError)
        }
    }

    func testRepeatedTakeWithRealStoredHeaderHandlesSerializedDatePrecision() async throws {
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        let controller = StationController(capture: capture, persistence: LiveStationPersistence(),
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        controller.report = capabilityReport()
        defer { if let id = controller.session?.sessionId { try? SessionStore.deleteSession(id) } }
        let recipe = recipeFixture(steps: [try .validated(sensor: .wide, captureSet: recipeSet())])
        for index in [1, 2] {
            let outcome = await controller.captureTake(recipe: RecipeSnapshot(recipe))
            guard case .completed(_, let station) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(station.stationIndex, index)
        }
    }

    func testCaptureRefusesMissingHeaderCalibrationOrUnreadableRunBeforeBookmarkAndCamera() async throws {
        for invalid in ["missing", "calibration", "unreadable"] {
            let report = capabilityReport()
            let capture = FakeStationCapture()
            let persistence = FakeStationPersistence(report: report)
            let controller = makeController(report: report, capture: capture, persistence: persistence)
            controller.startFlow()
            persistence.missingHeader = invalid == "missing"
            persistence.headerType = invalid == "calibration" ? "calibration" : "scene"
            persistence.unreadable = invalid == "unreadable" ? ["station-001.json"] : []
            let recipe = recipeFixture(steps: [try .validated(sensor: .wide, captureSet: recipeSet())])
            let outcome = await controller.captureTake(recipe: RecipeSnapshot(recipe), onRunReady: { _ in XCTFail("must not replace bookmark") })
            guard case .blocked = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(capture.requests.isEmpty)
            XCTAssertTrue(persistence.deletedStations.isEmpty)
        }
    }

    func testCoordinatorBootSelectsStarterWithoutOpeningRunThenCapturesAndRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = SelectedRecipeStore(url: root.appendingPathComponent("selected.json"))
        let recipes = RecipeStore(root: root.appendingPathComponent("recipes"), selection: selection,
                                  migrationURL: root.appendingPathComponent("migration.json"))
        let runs = ActiveRunStore(url: root.appendingPathComponent("run.json"))
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        func coordinator() -> RecipeCoordinator {
            RecipeCoordinator(station: StationController(capture: capture, persistence: persistence,
                motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate),
                recipes: recipes, selection: selection, runs: runs, loadLegacy: { nil }, clearLegacy: {})
        }
        let first = coordinator()
        try first.boot(report: report)
        XCTAssertNotNil(first.selectedRecipe)
        XCTAssertEqual(persistence.openCount, 0)
        XCTAssertTrue(capture.requests.isEmpty)
        await first.capture()
        XCTAssertEqual(capture.requests.count, 1)
        XCTAssertEqual(try runs.pointer()?.sessionID, "test-session")
        let relaunched = coordinator()
        try relaunched.boot(report: report)
        XCTAssertEqual(relaunched.selectedRecipe, first.selectedRecipe)
        XCTAssertEqual(persistence.openCount, 1)
        await relaunched.capture()
        XCTAssertEqual(persistence.writtenStation?.stationIndex, 2)
        XCTAssertEqual(persistence.openCount, 1)
        try relaunched.finishRun()
        XCTAssertNil(try runs.pointer())
        XCTAssertEqual(persistence.writtenStations.count, 2)
    }

    func testRecipeEstimateChargesAuthoredDwellAndOnlyRealFrameIntervals() throws {
        let base = ShotListEntry(index: 0, sensor: .wide, captureSet: recipeSet(count: 3, firing: .sequential))
        let timed = ShotListEntry(index: 0, sensor: .wide, captureSet: base.captureSet,
                                  dwellSeconds: 2, minimumGapSeconds: 1)
        let estimate = SessionEstimate.forShotList([timed], minimumGap: 99, profile: .reference)
        let baseline = SessionEstimate.forShotList([base], minimumGap: 0, profile: .reference)
        XCTAssertEqual(estimate.breakdown.settles - baseline.breakdown.settles, 2, accuracy: 0.0001)
        // Two 1 s start-to-start intervals, each already covering .01 s of
        // exposure and .233 s of pipeline work.
        XCTAssertEqual(estimate.breakdown.gaps, 1.514, accuracy: 0.0001)
        let single = ShotListEntry(index: 0, sensor: .wide, captureSet: recipeSet(firing: .sequential), minimumGapSeconds: 1)
        XCTAssertEqual(SessionEstimate.forShotList([single], minimumGap: 99).breakdown.gaps, 0)
    }

    func testOneCaptureIntentBanksEveryStepAndRepeatsInSameRun() async throws {
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        let controller = StationController(capture: capture, persistence: persistence,
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        controller.report = report
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0.2),
            try .validated(sensor: .wide, captureSet: recipeSet(firing: .sequential),
                           dwellSeconds: 0.3, sequentialGapSeconds: 0.5)])
        for index in [1, 2] {
            let result = await controller.captureTake(recipe: RecipeSnapshot(recipe))
            guard case .completed(let correlation, let station) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(station.stationIndex, index)
            XCTAssertEqual(station.brackets.count, 2)
            XCTAssertEqual(station.recipeSnapshot?.capturedDefinition, recipe)
            XCTAssertEqual(station.correlationID, correlation)
            XCTAssertEqual(station.brackets.map(\.dwellSeconds), [0.2, 0.3])
            XCTAssertEqual(station.brackets.map(\.minimumInterFrameGapSeconds), [nil, 0.5])
            XCTAssertFalse(controller.busy)
        }
        XCTAssertEqual(persistence.openCount, 1)
        XCTAssertEqual(capture.requests.map(\.minimumGap), [0, 0.5, 0, 0.5])
    }

    func testSecondStepFailureAndBankFailureDeleteWholeTake() async throws {
        for failBank in [false, true] {
            let report = capabilityReport()
            let persistence = FakeStationPersistence(report: report)
            persistence.failWrite = failBank
            let capture = FakeStationCapture()
            capture.emitsFrame = true
            capture.errorOnRequest = failBank ? nil : 2
            let controller = StationController(capture: capture, persistence: persistence,
                motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
            controller.report = report
            let recipe = recipeFixture(steps: [
                try .validated(sensor: .wide, captureSet: recipeSet()),
                try .validated(sensor: .wide, captureSet: recipeSet())])
            let outcome = await controller.captureTake(recipe: RecipeSnapshot(recipe))
            guard case .failed = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(persistence.writtenStations.isEmpty)
            XCTAssertEqual(persistence.deletedStations, [1])
            XCTAssertEqual(controller.phase, .sessionOpen)
            XCTAssertTrue(controller.pendingBrackets.isEmpty)
            XCTAssertFalse(controller.busy)
        }
    }

    func testStopAtReturnedRequestBoundaryDoesNotBankOrStartAnotherStep() async throws {
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        let controller = StationController(capture: capture, persistence: persistence,
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        controller.report = report
        capture.onCapture = { controller.requestStop() }
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .wide, captureSet: recipeSet(firing: .sequential)),
            try .validated(sensor: .wide, captureSet: recipeSet())])
        let outcome = await controller.captureTake(recipe: RecipeSnapshot(recipe))
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(capture.requests.count, 1)
        XCTAssertTrue(capture.requests[0].shouldStop())
        XCTAssertTrue(persistence.writtenStations.isEmpty)
        XCTAssertEqual(persistence.deletedStations, [1])
        XCTAssertEqual(controller.lastFault, .abandoned)
    }

    func testStopLeavesSuspendedCameraRequestAliveUntilItsResponseReturns() async throws {
        let report = capabilityReport()
        let capture = FakeStationCapture()
        let persistence = FakeStationPersistence(report: report)
        capture.emitsFrame = true
        let entered = expectation(description: "camera request is in flight")
        let finished = expectation(description: "Take finished after response release")
        var release: CheckedContinuation<Void, Never>?
        capture.holdResponse = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
            XCTAssertFalse(Task.isCancelled, "Stop must not cancel an active camera request")
        }
        let controller = StationController(capture: capture, persistence: persistence,
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        controller.report = report
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .wide, captureSet: recipeSet()),
            try .validated(sensor: .wide, captureSet: recipeSet())])
        var result: TakeOutcome?
        let task = Task {
            result = await controller.captureTake(recipe: RecipeSnapshot(recipe))
            finished.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        capture.holdResponse = nil // Any erroneously issued second request must not hang the test.
        controller.requestStop()
        XCTAssertTrue(controller.busy)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertTrue(persistence.deletedStations.isEmpty)
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        let outcome = try XCTUnwrap(result)
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(capture.requests.count, 1)
        XCTAssertEqual(persistence.deletedStations, [1])
        XCTAssertTrue(persistence.writtenStations.isEmpty)
    }

    func testUnsupportedRecipeDoesNotOpenARunOrDisturbCurrentDraft() async throws {
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let controller = StationController(capture: FakeStationCapture(), persistence: persistence,
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        controller.report = report
        controller.shotList.entries = [entry(.wide, frames: 1)]
        let before = controller.shotList
        let invalid = recipeFixture(steps: [try .validated(sensor: .telephoto, captureSet: recipeSet())])
        guard case .blocked = await controller.captureTake(recipe: RecipeSnapshot(invalid)) else { return XCTFail() }
        XCTAssertEqual(persistence.openCount, 0)
        XCTAssertEqual(controller.shotList, before)
    }

    func testResumeRevalidatesRecordsAndContinuesInANewTimeSegment() async throws {
        let report = capabilityReport()
        let persistence = FakeStationPersistence(report: report)
        let capture = FakeStationCapture()
        capture.emitsFrame = true
        let old = makeController(report: report, capture: capture, persistence: persistence)
        old.shotList.entries = [entry(.wide, frames: 1)]
        old.phase = .sessionOpen
        old.declareStation()
        await old.beginNextSet()
        old.closeStation()
        let oldSegment = try XCTUnwrap(persistence.writtenStation?.captureSegmentID)
        let resumed = StationController(capture: capture, persistence: persistence,
            motion: FakeStationMotion(), health: FakeStationHealth(), clock: .immediate)
        resumed.report = report
        try resumed.resumeRun(.init(sessionID: "test-session", nextTakeIndex: 100))
        XCTAssertEqual(resumed.stationIndex, 1, "derive from records again, not a stale recovery cursor")
        resumed.shotList.entries = [entry(.wide, frames: 1)]
        resumed.declareStation()
        await resumed.beginNextSet()
        resumed.closeStation()
        XCTAssertEqual(persistence.writtenStation?.stationIndex, 2)
        XCTAssertNotEqual(persistence.writtenStation?.captureSegmentID, oldSegment)
        XCTAssertThrowsError(try resumed.resumeRun(.init(sessionID: "test-session", nextTakeIndex: 2)))
    }

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
        let delivered = try XCTUnwrap(frame.deliveredAtSegmentStartSeconds)
        let latestMotion = try XCTUnwrap(frame.latestMotionAtSegmentStartSeconds)
        let stationMotion = try XCTUnwrap(station.motion)
        let swapMotion = try XCTUnwrap(station.sensorSwaps.first?.motion)
        let motionAtFire = try XCTUnwrap(station.brackets.first?.motionAtFire)

        XCTAssertEqual(frame.capturedAtSegmentStartSeconds, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(delivered, 2.6, accuracy: 0.000_001)
        XCTAssertEqual(latestMotion, 2.55, accuracy: 0.000_001)
        XCTAssertEqual(stationMotion.windowStart, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(stationMotion.windowEnd, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(swapMotion.windowStart, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(swapMotion.windowEnd, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(motionAtFire.windowStart, 0, accuracy: 0.000_001)
        XCTAssertEqual(motionAtFire.windowEnd, 0.4, accuracy: 0.000_001)

        let persistedOffsets = [
            frame.capturedAtSegmentStartSeconds, delivered, latestMotion,
            stationMotion.windowStart, stationMotion.windowEnd,
            swapMotion.windowStart, swapMotion.windowEnd,
            motionAtFire.windowStart, motionAtFire.windowEnd,
        ]
        for offset in persistedOffsets {
            XCTAssertGreaterThanOrEqual(offset, 0,
                                        "persisted segment offsets must never be negative")
        }
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
    var errorOnRequest: Int?
    var onCapture: (() -> Void)?
    var holdResponse: (() async -> Void)?
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
        onCapture?()
        await holdResponse?()
        if errorOnRequest == requests.count { throw FakeError.capture }
        if let captureError { throw captureError }
        let frames = emitsFrame ? [frameFixture(request: request)] : []
        return SetShot(frames: frames, bracketRequestSizes: [request.specs.count])
    }
    func stop() { stopCount += 1 }
}

private final class FakeStationPersistence: StationPersisting {
    var openCount = 0
    var failWrite = false
    var missingHeader = false
    var headerType = "scene"
    var unreadable: [String] = []
    let report: CapabilityReport
    var hasRoom = true
    var writtenStations: [StationRecord] = []
    var deletedStations: [Int] = []
    var writtenStation: StationRecord? { writtenStations.last }
    init(report: CapabilityReport) { self.report = report }
    func loadSession(_ id: String) -> SessionRecord? {
        guard id == "test-session", !missingHeader else { return nil }
        return SessionRecord(sessionId: id, openedAt: Date(timeIntervalSince1970: 10),
                             capability: report, availableCapacityBytes: 1_000_000_000, sessionType: headerType)
    }
    func loadStationsDetailed(_ id: String) -> (stations: [StationRecord], unreadable: [String]) {
        (writtenStations, unreadable)
    }
    func open(capability: CapabilityReport) throws -> SessionRecord {
        openCount += 1
        return SessionRecord(sessionId: "test-session", openedAt: Date(timeIntervalSince1970: 10),
                      capability: capability, availableCapacityBytes: 1_000_000_000)
    }
    func hasRoom(forFrames count: Int) -> Bool { hasRoom }
    func writeMotionStream(_ samples: [MotionSample], sessionId: String,
                           station: Int) throws -> String { "motion.jsonl" }
    func writeStation(_ station: StationRecord) throws {
        if failWrite { throw FakeError.capture }
        writtenStations.append(station)
    }
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
        photoTimestampAtSegmentStartSeconds: nil,
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
