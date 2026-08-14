import Foundation

/// Pre-flight timing and storage estimates for a shot list.
///
/// **Every figure comes from `DeviceProfile.active`**, not from constants here.
/// That is the whole point: the numbers this screen shows were, until
/// recently, measured once on one iPhone 15 Pro and presented as though they
/// were anyone's. They now come from whatever has actually been measured on the
/// device in hand, falling back to that reference phone and *saying so* when it
/// has not.
///
/// An estimate built from a borrowed figure is not worthless — it is the best
/// available guess — but it must not read the same as a measured one.
struct SessionEstimate {

    /// How many hardware requests a set of `frames` takes on a sensor whose
    /// bracket ceiling is `ceiling`.
    static func requestCount(frames: Int, ceiling: Int) -> Int {
        guard ceiling > 0, frames > 0 else { return 0 }
        return Int((Double(frames) / Double(ceiling)).rounded(.up))
    }

    // MARK: - Results

    /// The profile these figures were computed against, so a plan can say
    /// whether it rests on measurement or on a borrowed reference.
    let profile: DeviceProfile

    let frameCount: Int
    let sensorSwaps: Int
    /// Extra hardware requests beyond one per set, from sets longer than the
    /// sensor's bracket ceiling. Zero for sequential runs and for sets that fit.
    let bracketSeams: Int
    /// Exposure time alone — the irreducible part.
    let exposureSeconds: TimeInterval
    /// Everything that is not exposure: swaps, per-frame overhead, waits.
    let overheadSeconds: TimeInterval
    let stillnessWorstCaseSeconds: TimeInterval

    /// Where the time actually goes, kept separately rather than reverse-derived.
    ///
    /// The single most useful thing a plan can say is that most of a
    /// three-sensor station is *not* shooting — and that only lands if the
    /// parts are drawn against each other. Reconstructing them from
    /// `overheadSeconds` afterwards would mean the display and the arithmetic
    /// could drift.
    struct Breakdown: Equatable {
        var exposure: TimeInterval = 0
        /// Reconfiguring for a different sensor.
        var swaps: TimeInterval = 0
        /// The stillness wait after each swap.
        var settles: TimeInterval = 0
        /// Boundaries between hardware requests, on sets past the ceiling.
        var seams: TimeInterval = 0
        /// The pipeline's own cost per frame — frame period, or the sequential
        /// round trip.
        var perFrame: TimeInterval = 0
        /// An operator-chosen floor on frame spacing, sequential only.
        var gaps: TimeInterval = 0

        var total: TimeInterval { exposure + swaps + settles + seams + perFrame + gaps }
        /// The fraction of a station spent doing anything other than exposing.
        var notShooting: Double { total > 0 ? 1 - exposure / total : 0 }

        var parts: [(name: String, seconds: TimeInterval)] {
            [("Exposure", exposure), ("Sensor swaps", swaps), ("Settling", settles),
             ("Bracket seams", seams), ("Pipeline", perFrame), ("Gaps", gaps)]
                .filter { $0.1 > 0 }
        }
    }

    let breakdown: Breakdown

    var typicalSeconds: TimeInterval { exposureSeconds + overheadSeconds }
    var worstCaseSeconds: TimeInterval { typicalSeconds + stillnessWorstCaseSeconds }

    var typicalBytes: Int64 { Int64(frameCount) * Int64(profile.averageFrameBytes.value) }
    var worstCaseBytes: Int64 { Int64(frameCount) * Int64(profile.worstCaseFrameBytes.value) }

    /// Nil when capacity cannot be read. True only if the **worst case** fits —
    /// an estimate that says "probably fits" is not worth having when the
    /// failure mode is a station aborting mid-shoot.
    var fitsAvailableStorage: Bool? {
        guard let free = SessionStore.availableCapacityBytes() else { return nil }
        return free > worstCaseBytes
    }

    // MARK: - Building

    /// `bracketCeiling` is how many frames fit in one hardware request on the
    /// sensors in play. Passing nil skips seam accounting, which is right for a
    /// sequential run and for a caller that does not yet know the ceiling.
    static func forShotList(_ entries: [ShotListEntry],
                            minimumGap: TimeInterval, includeStillness: Bool = true,
                            bracketCeiling: Int? = nil,
                            profile: DeviceProfile = .active) -> SessionEstimate {
        var frames = 0
        var exposure: TimeInterval = 0
        var overhead: TimeInterval = 0
        var swaps = 0
        var seams = 0
        var parts = Breakdown()
        var previousSensor: SensorCapability.Sensor?

        for entry in entries {
            if entry.sensor != previousSensor {
                swaps += 1
                overhead += profile.sensorSwap.value
                parts.swaps += profile.sensorSwap.value
            }
            previousSensor = entry.sensor

            let specs = entry.captureSet.rendered(for: entry.sensor)
            frames += specs.count

            // Firing mode belongs to the set, so a shot list may mix them.
            let firing = entry.captureSet.firing

            // A set past the ceiling is split across requests, and each seam
            // costs seventeen times an in-request gap.
            if firing == .hardwareBracket, let ceiling = bracketCeiling {
                let extra = Swift.max(0, requestCount(frames: specs.count, ceiling: ceiling) - 1)
                seams += extra
                overhead += Double(extra) * profile.bracketSeam.value
                parts.seams += Double(extra) * profile.bracketSeam.value
            }

            for spec in specs {
                exposure += spec.shutterSeconds
                parts.exposure += spec.shutterSeconds
                switch firing {
                case .hardwareBracket:
                    // The pipeline holds a frame period per frame unless the
                    // exposure itself is longer, in which case exposure covers it.
                    let held = Swift.max(0, profile.sensorFramePeriod.value - spec.shutterSeconds)
                    overhead += held
                    parts.perFrame += held
                case .sequential:
                    overhead += profile.sequentialOverheadPerFrame.value
                    parts.perFrame += profile.sequentialOverheadPerFrame.value
                }
                // Only sequential can honour a gap — a burst is one request
                // with nowhere to insert a wait — so charging for it in a burst
                // predicted time the app was never going to spend.
                if firing == .sequential { overhead += minimumGap; parts.gaps += minimumGap }
            }
        }
        if includeStillness { parts.settles = Double(swaps) * profile.stillnessTimeout.value }
        return SessionEstimate(
            profile: profile,
            frameCount: frames, sensorSwaps: swaps, bracketSeams: seams,
            exposureSeconds: exposure, overheadSeconds: overhead,
            stillnessWorstCaseSeconds: includeStillness ? Double(swaps) * profile.stillnessTimeout.value : 0,
            breakdown: parts)
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        if t < 1 { return String(format: "%.0f ms", t * 1000) }
        if t < 60 { return String(format: "%.1f s", t) }
        return String(format: "%d min %02d s", Int(t) / 60, Int(t) % 60)
    }

    static func formatBytes(_ b: Int64) -> String {
        b < 1_000_000_000
            ? String(format: "%d MB", b / 1_000_000)
            : String(format: "%.2f GB", Double(b) / 1_000_000_000)
    }
}
