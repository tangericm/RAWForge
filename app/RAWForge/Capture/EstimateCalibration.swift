import Foundation

/// Corrects the pre-flight estimate against what stations actually took.
///
/// The estimate's constants were measured on a cool device with a warm battery
/// and nothing else running. Thermal throttling moves them and does not
/// announce itself: `ProcessInfo.thermalState` reaching `.serious` means the
/// system is slowing capture, but by how much is not exposed.
///
/// Rather than guess a derating factor, this reads it off the record. Every
/// station already stores `estimatedSeconds` alongside `openedAt` and
/// `closedAt`, so the ratio between predicted and actual is sitting in the logs
/// — which means the estimate calibrates itself against this device, in these
/// conditions, with no extra state file and nothing to keep in sync.
///
/// The median is used rather than the mean: one station where the operator
/// stopped to think between sets would otherwise skew every subsequent estimate.
struct EstimateCalibration {

    /// 1.0 means the estimate matched. 1.4 means stations are running 40%
    /// longer than predicted, which is what throttling looks like from here.
    let factor: Double
    let sampleCount: Int

    static let identity = EstimateCalibration(factor: 1.0, sampleCount: 0)

    /// Below this the correction is noise, and applying it would make the
    /// estimate worse rather than better.
    static let minimumSamples = 3

    var isUseful: Bool { sampleCount >= Self.minimumSamples }

    func apply(_ seconds: TimeInterval) -> TimeInterval {
        isUseful ? seconds * factor : seconds
    }

    var summary: String? {
        guard isUseful else { return nil }
        let pct = (factor - 1) * 100
        if abs(pct) < 5 { return "estimates tracking actuals (\(sampleCount) stations)" }
        return String(format: "stations running %+.0f%% against estimate (%d samples) — applied",
                      pct, sampleCount)
    }

    /// Derived from the most recent stations that carry an estimate.
    static func fromRecentStations(limit: Int = 12) -> EstimateCalibration {
        var ratios: [Double] = []
        for sessionId in SessionStore.existingSessionIds().reversed() {
            for station in SessionStore.loadStations(sessionId) {
                guard let estimated = station.estimatedSeconds, estimated > 0.5 else { continue }
                let actual = station.closedAt.timeIntervalSince(station.openedAt)
                // A station that took ten times its estimate had something
                // happen to it that is not throttling — an operator pause, a
                // phone call — and is not evidence about capture speed.
                guard actual > 0, actual / estimated < 5 else { continue }
                ratios.append(actual / estimated)
                if ratios.count >= limit { break }
            }
            if ratios.count >= limit { break }
        }
        guard !ratios.isEmpty else { return .identity }
        let sorted = ratios.sorted()
        return EstimateCalibration(factor: sorted[sorted.count / 2], sampleCount: sorted.count)
    }
}
