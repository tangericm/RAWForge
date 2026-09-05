import XCTest
@testable import RAWForge

@MainActor
final class CaptureBoundaryTests: XCTestCase {
    func testStopDuringEitherWaitDoesNotIssueNextFrameOrBurst() async {
        for waitKind in ["Sequential interval", "Burst seam"] {
            var stopped = false
            var fired = false
            do {
                _ = try await CaptureRequestBoundary.perform(shouldStop: { stopped }, wait: { stopped = true }) {
                    fired = true
                    return 1
                }
                XCTFail("\(waitKind) must cancel")
            } catch CaptureInterruption.stopRequested {
                XCTAssertFalse(fired)
            } catch { XCTFail("\(error)") }
        }
    }

    func testRequestAlreadyInFlightFinishesBeforeCallerChecksStop() async throws {
        var stopped = false
        let result = try await CaptureRequestBoundary.perform(shouldStop: { stopped }, wait: {}) {
            stopped = true
            return 8
        }
        XCTAssertEqual(result, 8, "the caller must still receive and bank a whole hardware response")
    }
}
