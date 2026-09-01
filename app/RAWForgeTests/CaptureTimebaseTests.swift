import XCTest
@testable import RAWForge

final class CaptureTimebaseTests: XCTestCase {
    func testRawUptimeBecomesRunRelativeTime() {
        let timebase = CaptureTimebase(segmentID: "test-segment", originUptime: 1_000)
        XCTAssertEqual(timebase.secondsSinceOrigin(1_003.25), 3.25, accuracy: 0.000_001)
    }

    func testClockSkewBeforeOriginNeverProducesNegativePersistedTime() {
        let timebase = CaptureTimebase(segmentID: "test-segment", originUptime: 100)
        XCTAssertEqual(timebase.secondsSinceOrigin(99.9), 0)
    }

    func testMotionSummaryOffsetsOnlyItsWindow() {
        let original = MotionSummary.fixture(windowStart: 40, windowEnd: 41)
        let shifted = original.offsettingWindow(by: -40)
        XCTAssertEqual(shifted.windowStart, 0)
        XCTAssertEqual(shifted.windowEnd, 1)
        XCTAssertEqual(shifted.gyroP99, original.gyroP99)
    }
}

private extension MotionSummary {
    static func fixture(windowStart: TimeInterval, windowEnd: TimeInterval) -> MotionSummary {
        MotionSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            sampleCount: 100,
            effectiveHz: 100,
            worstGapSeconds: 0.01,
            gyroP50: 0.01,
            gyroP90: 0.02,
            gyroP99: 0.03,
            gyroMax: 0.04,
            accelP50: 0.1,
            accelP90: 0.2,
            accelP99: 0.3,
            accelMax: 0.4)
    }
}
