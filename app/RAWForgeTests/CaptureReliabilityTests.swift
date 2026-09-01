import AVFoundation
import XCTest
@testable import RAWForge

final class CaptureReliabilityTests: XCTestCase {

    func testOnlyTheFirstAsynchronousCompletionIsDelivered() {
        let lock = NSLock()
        var deliveryCount = 0
        let gate = LockedResultGate<Int> { _ in
            lock.lock()
            deliveryCount += 1
            lock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: 100) { value in
            gate.resolve(.success(value))
        }

        XCTAssertEqual(deliveryCount, 1,
                       "a timeout and a late AVFoundation callback must not both resume")
    }

    func testRequestDeadlineHasAFloorAndLeavesRoomForLongBrackets() {
        XCTAssertEqual(CaptureReliability.requestTimeout(exposureSeconds: [0.004]), 15)
        XCTAssertEqual(CaptureReliability.requestTimeout(exposureSeconds: Array(repeating: 1, count: 8)), 18)
    }

    func testAStoppedOrInterruptedSessionCannotEnterResourcePreparation() {
        XCTAssertTrue(CaptureReliability.sessionUnavailable(isRunning: false, isInterrupted: false))
        XCTAssertTrue(CaptureReliability.sessionUnavailable(isRunning: true, isInterrupted: true))
        XCTAssertFalse(CaptureReliability.sessionUnavailable(isRunning: true, isInterrupted: false))
    }

    func testOnlyCameraPipelineFailuresEarnTheOneBenchRecovery() {
        let sessionNotRunning = NSError(domain: AVFoundationErrorDomain,
                                        code: AVError.Code.sessionNotRunning.rawValue)
        XCTAssertTrue(CaptureReliability.shouldRecoverBench(after: sessionNotRunning,
                                                            recoveryCount: 0))
        XCTAssertFalse(CaptureReliability.shouldRecoverBench(after: sessionNotRunning,
                                                             recoveryCount: 1),
                       "a degraded camera must not enter an unbounded retry loop")
        XCTAssertFalse(CaptureReliability.shouldRecoverBench(
            after: CaptureRig.RigError.noDevice("wide"), recoveryCount: 0))
    }

    func testDiagnosticsKeepEveryNSErrorLayer() {
        let service = NSError(domain: "FigCaptureSourceRemote", code: -17_281,
                              userInfo: [NSLocalizedDescriptionKey: "invalid XPC channel"])
        let av = NSError(domain: AVFoundationErrorDomain,
                         code: AVError.Code.sessionNotRunning.rawValue,
                         userInfo: [NSUnderlyingErrorKey: service])

        let rendered = CaptureSessionDiagnostics.describe(error: av)
        XCTAssertTrue(rendered.contains("AVFoundationErrorDomain/-11803"))
        XCTAssertTrue(rendered.contains("FigCaptureSourceRemote/-17281"))
        XCTAssertTrue(rendered.contains("invalid XPC channel"))
    }

    func testInterruptionReasonsAreReadableRatherThanRawIntegers() {
        XCTAssertEqual(CaptureSessionDiagnostics.interruptionReasonName(
            AVCaptureSession.InterruptionReason.videoDeviceNotAvailableDueToSystemPressure.rawValue),
            "video unavailable due to system pressure")
        XCTAssertEqual(CaptureSessionDiagnostics.interruptionReasonName(9_999), "unknown(9999)")
    }
}
