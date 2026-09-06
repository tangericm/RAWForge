import Foundation

/// One conversion boundary for authored delays and the nanosecond sleep clock.
enum CaptureTiming {
    enum ValidationError: LocalizedError {
        case unsupportedDuration

        var errorDescription: String? {
            "Wait or interval is outside the supported clock range. Enter a smaller, non-negative duration."
        }
    }

    static func nanoseconds(for seconds: TimeInterval) throws -> UInt64 {
        let nanoseconds = seconds * 1_000_000_000
        // Double(UInt64.max) rounds UP to 2^64. Equality is already outside
        // the integer range, so the upper comparison must remain strict.
        guard seconds.isFinite, seconds >= 0,
              nanoseconds < Double(UInt64.max) else {
            throw ValidationError.unsupportedDuration
        }
        return UInt64(nanoseconds)
    }
}
