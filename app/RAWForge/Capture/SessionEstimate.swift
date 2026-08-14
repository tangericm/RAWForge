import Foundation

/// Pre-flight timing and storage estimates for a shot list.
///
/// Every constant here was **measured on this device**, not assumed, and the
/// provenance matters: an estimate built from guesses is worse than no estimate,
/// because it looks authoritative while being wrong. Where a figure is a
/// worst-case rather than a typical one, it says so.
struct SessionEstimate {

    // MARK: - Measured constants

    /// Hardware bracket: `gap = max(frame period, exposure)`. The frame period
    /// is 33.4 ms — exactly 1/30 s, the sensor's own cadence (#14 item 9).
    static let sensorFramePeriod: TimeInterval = 0.0334

    /// Sequential capture pays a per-request round trip through the pipeline
    /// that is *not* exposure and *not* settle. Measured 233-500 ms; the low end
    /// is a repeat run where nothing changed between frames, so this is the
    /// floor rather than the average.
    static let sequentialOverheadPerFrame: TimeInterval = 0.233

    /// Reconfiguring the session for a different sensor. Measured 367-422 ms
    /// across three swaps; longer than an entire 8-frame bracket.
    static let sensorSwap: TimeInterval = 0.40

    /// The stillness settle window, and it is a real expectation rather than a
    /// ceiling: it is the measured decay time of the tap transient, so a set
    /// pays it in full unless the device is already in the tripod band.
    ///
    /// Measured by replaying six motion streams in 0.2 s windows from station
    /// open — the first window runs 1.5-4.3x steady state on every mount and
    /// each reaches its baseline by 0.2-0.4 s.
    static let stillnessTimeout: TimeInterval = 0.4

    /// The seam between two hardware bracket requests, when a set is longer
    /// than the sensor's ceiling and has to be split.
    ///
    /// Measured on an iPhone 15 Pro: 16 frames as 8+8 put the gap inside a
    /// request at 33.4 ms — the sensor's own cadence — and the gap across the
    /// seam at **567 ms**. Seventeen times the in-request gap, so a plan that
    /// ignored it would badly under-estimate any long set.
    static let bracketSeam: TimeInterval = 0.567

    /// 1,675 real iPhone DNGs averaged 10.0 MB with a maximum of 30.7 MB (#11).
    static let averageFrameBytes: Int64 = 10_000_000
    static let worstCaseFrameBytes: Int64 = 30_700_000

    /// How many hardware requests a set of `frames` takes on a sensor whose
    /// bracket ceiling is `ceiling`.
    static func requestCount(frames: Int, ceiling: Int) -> Int {
        guard ceiling > 0, frames > 0 else { return 0 }
        return Int((Double(frames) / Double(ceiling)).rounded(.up))
    }

    // MARK: - Results

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

    var typicalSeconds: TimeInterval { exposureSeconds + overheadSeconds }
    var worstCaseSeconds: TimeInterval { typicalSeconds + stillnessWorstCaseSeconds }

    var typicalBytes: Int64 { Int64(frameCount) * Self.averageFrameBytes }
    var worstCaseBytes: Int64 { Int64(frameCount) * Self.worstCaseFrameBytes }

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
    static func forShotList(_ entries: [ShotListEntry], mode: ExecutionMode,
                            minimumGap: TimeInterval, includeStillness: Bool = true,
                            bracketCeiling: Int? = nil) -> SessionEstimate {
        var frames = 0
        var exposure: TimeInterval = 0
        var overhead: TimeInterval = 0
        var swaps = 0
        var seams = 0
        var previousSensor: SensorCapability.Sensor?

        for entry in entries {
            if entry.sensor != previousSensor { swaps += 1; overhead += sensorSwap }
            previousSensor = entry.sensor

            let specs = entry.captureSet.rendered(for: entry.sensor)
            frames += specs.count

            // A set past the ceiling is split across requests, and each seam
            // costs seventeen times an in-request gap.
            if mode == .hardwareBracket, let ceiling = bracketCeiling {
                let extra = Swift.max(0, requestCount(frames: specs.count, ceiling: ceiling) - 1)
                seams += extra
                overhead += Double(extra) * bracketSeam
            }

            for spec in specs {
                exposure += spec.shutterSeconds
                switch mode {
                case .hardwareBracket:
                    // The pipeline holds a frame period per frame unless the
                    // exposure itself is longer, in which case exposure covers it.
                    overhead += Swift.max(0, sensorFramePeriod - spec.shutterSeconds)
                case .sequential:
                    overhead += sequentialOverheadPerFrame
                }
                overhead += minimumGap
            }
        }
        return SessionEstimate(
            frameCount: frames, sensorSwaps: swaps, bracketSeams: seams,
            exposureSeconds: exposure, overheadSeconds: overhead,
            stillnessWorstCaseSeconds: includeStillness ? Double(swaps) * stillnessTimeout : 0)
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
