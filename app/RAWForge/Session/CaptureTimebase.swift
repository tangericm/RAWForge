import Foundation

struct CaptureTimebase: Equatable {
    static let persistedName = "secondsSinceCaptureSegmentStart"
    let segmentID: String
    let originUptime: TimeInterval

    func secondsSinceOrigin(_ uptime: TimeInterval) -> TimeInterval {
        max(0, uptime - originUptime)
    }
}

extension MotionSummary {
    func offsettingWindow(by offset: TimeInterval) -> MotionSummary {
        MotionSummary(
            windowStart: max(0, windowStart + offset),
            windowEnd: max(0, windowEnd + offset),
            sampleCount: sampleCount,
            effectiveHz: effectiveHz,
            worstGapSeconds: worstGapSeconds,
            gyroP50: gyroP50,
            gyroP90: gyroP90,
            gyroP99: gyroP99,
            gyroMax: gyroMax,
            accelP50: accelP50,
            accelP90: accelP90,
            accelP99: accelP99,
            accelMax: accelMax)
    }
}
