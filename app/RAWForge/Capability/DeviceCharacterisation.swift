import AVFoundation
import Foundation

/// Measures the timings the plan is built from, on the device in hand.
///
/// Every figure in `SessionEstimate` used to come from ad-hoc runs on one
/// iPhone 15 Pro, over months, by hand. This is the same measurements as a
/// feature: the app performs them itself, on whatever hardware it is running on,
/// and records what it found along with how many samples it took.
///
/// **It writes no frames and opens no session.** A characterisation is not data
/// — it is the app taking its own measurements — so the captures it makes are
/// read for their timestamps and sizes and then released. That also keeps it
/// cheap enough that nobody has a reason to skip it.
///
/// It does not need a capped lens: none of the timings depend on what the lens
/// is pointed at. Frame *size* does, which is why the run treats it as a floor
/// rather than a ceiling (see `DeviceProfile.noteObservedFrame`).
@MainActor
enum DeviceCharacterisation {

    /// Sample counts, chosen so the whole run stays under about twenty seconds.
    /// A run nobody waits for is a run nobody performs, and a borrowed figure
    /// is what that leaves behind.
    private static let sequentialSamples = 5
    private static let sameSensorSamples = 7
    private static let swapSamples = 3

    struct Step {
        let label: String
        let index: Int
        let total: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case noUsableSensor
        case notEnoughFrames(String)
        case cameraDidNotRecover(String)

        var description: String {
            switch self {
            case .noUsableSensor:
                return "no sensor on this device delivers Bayer RAW, so there is nothing to measure"
            case .notEnoughFrames(let what):
                return "not enough frames came back to measure \(what)"
            case .cameraDidNotRecover(let detail):
                return "the camera did not recover after one automatic reset — \(detail). "
                    + "Close other camera apps; if the preview remains black, restart the iPhone. "
                    + "The Console log contains the session diagnostics."
            }
        }
    }

    /// Runs every measurement this device supports and returns a profile.
    ///
    /// Measurements that cannot be taken on this hardware — a swap on a
    /// single-sensor phone, a seam where the whole set fits one request — keep
    /// the reference value and stay marked borrowed. That is the honest
    /// outcome: the app did not measure it, and says so.
    static func run(rig: CaptureRig,
                    report: CapabilityReport,
                    onStep: @escaping (Step) -> Void = { _ in }) async throws -> DeviceProfile {
        do {
            return try await runOnce(rig: rig, report: report, onStep: onStep)
        } catch {
            guard CaptureReliability.shouldRecoverBench(after: error, recoveryCount: 0) else {
                throw error
            }
            logWarn(.probe, "characterisation capture failed — attempting one camera-graph reset")
            do {
                try await rig.rebuildAfterCaptureFailure(error)
                return try await runOnce(rig: rig, report: report, onStep: onStep)
            } catch {
                logFailure(.probe, "characterisation retry after camera-graph reset", error)
                throw Failure.cameraDidNotRecover(
                    CaptureSessionDiagnostics.describe(error: error))
            }
        }
    }

    private static func runOnce(rig: CaptureRig,
                                report: CapabilityReport,
                                onStep: @escaping (Step) -> Void) async throws -> DeviceProfile {

        let sensors = report.usableSensors
        guard let first = sensors.first else { throw Failure.noUsableSensor }

        let reference = DeviceProfile.reference
        let identity = DeviceIdentity.current()
        let iso = max(first.minISO ?? 100, 100)
        let shutter = 1.0 / 250.0
        let began = ProcessInfo.processInfo.systemUptime
        logInfo(.probe, "characterisation starting on \(identity.modelIdentifier)")

        var total = 4                       // frame period, seam, sequential, reuse
        if sensors.count > 1 { total += 1 }             // swap

        var frameSizes: [Int] = []

        // 1 — Frame period: the gap between frames inside one hardware request.
        onStep(Step(label: "Frame period", index: 1, total: total))
        try await rig.configure(first.sensor)
        await rig.startSessionAndWait()
        try await rig.requireSessionAvailable("Device Characterisation")
        _ = try await rig.lockWhiteBalance()

        let ceiling = rig.maxBracketCount
        var framePeriod = reference.sensorFramePeriod
        var seam = reference.bracketSeam

        let periodSamples = framePeriodSampleCount(bracketCeiling: ceiling)
        if periodSamples >= 3 {
            var stamps: [Double] = []
            _ = try await rig.captureBracket(specs(count: periodSamples, shutter: shutter, iso: iso)) { photo, _ in
                stamps.append(photo.timestamp.seconds)
                if let d = photo.fileDataRepresentation() { frameSizes.append(d.count) }
            }
            let gaps = differences(stamps)
            guard gaps.count >= 2 else { throw Failure.notEnoughFrames("the frame period") }
            framePeriod = .measured(median(gaps), samples: gaps.count, spread: spread(gaps))
            logInfo(.probe, String(format: "frame period %.1f ms over %d gap(s)",
                                   framePeriod.value * 1000, gaps.count))
        } else {
            logWarn(.probe, "bracket ceiling is \(ceiling) — too small to measure a frame period; "
                    + "keeping the borrowed value")
        }

        // 2 — Seam: the gap across two hardware requests, which only exists on a
        // set longer than the ceiling.
        onStep(Step(label: "Bracket seam", index: 2, total: total))
        if ceiling >= 1 {
            var stamps: [Double] = []
            let sizes = try await rig.captureBracket(
                specs(count: ceiling + 1, shutter: shutter, iso: iso)
            ) { photo, _ in
                stamps.append(photo.timestamp.seconds)
                if let d = photo.fileDataRepresentation() { frameSizes.append(d.count) }
            }
            // The seam sits at the boundary between the first request and the
            // second; every other gap is an in-request one.
            if sizes.count > 1, let boundary = sizes.first, stamps.count > boundary {
                let across = stamps[boundary] - stamps[boundary - 1]
                seam = .measured(across, samples: 1, spread: 0)
                logInfo(.probe, String(format: "bracket seam %.0f ms", across * 1000))
            } else {
                logWarn(.probe, "the set did not split, so there was no seam to measure")
            }
        }

        // 3 — Sequential overhead: the per-frame cost of a capture that
        // reconfigures the device between rungs.
        onStep(Step(label: "Sequential overhead", index: 3, total: total))
        var sequential = reference.sequentialOverheadPerFrame
        var perFrame: [Double] = []
        for _ in 0..<sequentialSamples {
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = try await rig.lockExposure(shutterSeconds: shutter, iso: iso)
            let photo = try await rig.captureSingle()
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            if let d = photo.fileDataRepresentation() { frameSizes.append(d.count) }
            // The exposure itself is not overhead — it is the thing being paid
            // for — so it comes off before the figure is recorded.
            perFrame.append(max(0, elapsed - shutter))
        }
        if perFrame.count >= 2 {
            sequential = .measured(median(perFrame), samples: perFrame.count, spread: spread(perFrame))
            logInfo(.probe, String(format: "sequential overhead %.0f ms/frame over %d",
                                   sequential.value * 1000, perFrame.count))
        }

        // 4 — Same-sensor setup: the graph is already live, so this measures
        // the cheap idempotent path rather than borrowing the cost of a swap.
        onStep(Step(label: "Same-sensor setup", index: 4, total: total))
        var sameSensorDurations: [Double] = []
        for _ in 0..<sameSensorSamples {
            let t0 = ProcessInfo.processInfo.systemUptime
            try await rig.configure(first.sensor)
            await rig.startSessionAndWait()
            try await rig.requireSessionAvailable("same-sensor timing")
            sameSensorDurations.append(ProcessInfo.processInfo.systemUptime - t0)
        }
        let sameSensorSetup = Reading.measured(
            median(sameSensorDurations), samples: sameSensorDurations.count,
            spread: spread(sameSensorDurations))
        logInfo(.probe, String(format: "same-sensor setup %.3f ms over %d",
                               sameSensorSetup.value * 1000, sameSensorDurations.count))

        // 5 — Swap: reconfiguring for a different sensor, which on a
        // single-sensor phone simply never happens.
        var swap = reference.sensorSwap
        if sensors.count > 1 {
            onStep(Step(label: "Sensor swap", index: 5, total: total))
            var durations: [Double] = []
            for i in 0..<swapSamples {
                let target = sensors[(i + 1) % sensors.count].sensor
                let t0 = ProcessInfo.processInfo.systemUptime
                try await rig.configure(target)
                await rig.startSessionAndWait()
                try await rig.requireSessionAvailable("sensor-swap timing")
                durations.append(ProcessInfo.processInfo.systemUptime - t0)
            }
            swap = .measured(median(durations), samples: durations.count, spread: spread(durations))
            logInfo(.probe, String(format: "sensor swap %.0f ms over %d",
                                   swap.value * 1000, durations.count))
        } else {
            logInfo(.probe, "one usable sensor — no swap to measure, keeping the borrowed value")
        }

        rig.stopSession()

        // Frame size, from whatever the lens happened to see. A floor, not a
        // ceiling — the worst case is learned from real captures instead.
        var averageBytes = reference.averageFrameBytes
        var worstBytes = reference.worstCaseFrameBytes
        if frameSizes.count >= 3 {
            let mean = Double(frameSizes.reduce(0, +)) / Double(frameSizes.count)
            averageBytes = .measured(mean, samples: frameSizes.count,
                                     spread: Double((frameSizes.max() ?? 0) - (frameSizes.min() ?? 0)))
            worstBytes = .measured(Double(frameSizes.max() ?? 0), samples: frameSizes.count, spread: 0)
            logInfo(.probe, "frame size \(Int(mean / 1_000_000)) MB average over \(frameSizes.count)")
        }

        let profile = DeviceProfile(
            modelIdentifier: identity.modelIdentifier,
            systemVersion: identity.systemVersion,
            appVersion: "\(identity.appVersion) (\(identity.appBuild))",
            measuredAt: Date(),
            sensorFramePeriod: framePeriod,
            sequentialOverheadPerFrame: sequential,
            sensorSwap: swap,
            sameSensorSetup: sameSensorSetup,
            bracketSeam: seam,
            averageFrameBytes: averageBytes,
            worstCaseFrameBytes: worstBytes,
            // Not measurable by any capture run — see DeviceProfile.
            stillnessTimeout: reference.stillnessTimeout)

        logInfo(.probe, String(format: "characterisation finished in %.1f s · %d frame(s) · "
                               + "%d reading(s) still borrowed",
                               ProcessInfo.processInfo.systemUptime - began,
                               frameSizes.count, profile.borrowedCount))
        return profile
    }

    // MARK: - Arithmetic

    /// Four frames produce three gaps: enough for a median to reject one
    /// delayed frame without allocating the maximum RAW bracket merely to
    /// estimate an in-request period. The separate seam step still exercises
    /// the true hardware ceiling, after resources have been prepared.
    nonisolated static func framePeriodSampleCount(bracketCeiling: Int) -> Int {
        bracketCeiling >= 3 ? min(4, bracketCeiling) : 0
    }

    private static func specs(count: Int, shutter: Double, iso: Float) -> [CaptureSpec] {
        (0..<count).map { _ in CaptureSpec(shutterSeconds: shutter, iso: iso) }
    }

    /// Pure arithmetic, deliberately not actor-isolated: these are the parts of
    /// the run that can be checked without a sensor, and a test should not have
    /// to hop to the main actor to verify a subtraction.
    nonisolated static func differences(_ xs: [Double]) -> [Double] {
        guard xs.count > 1 else { return [] }
        return (1..<xs.count).map { xs[$0] - xs[$0 - 1] }
    }

    /// Median rather than mean throughout: one frame delayed by something
    /// unrelated should not move a figure the whole plan is built on.
    nonisolated static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
                                : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    nonisolated static func spread(_ xs: [Double]) -> Double {
        guard let lo = xs.min(), let hi = xs.max() else { return 0 }
        return hi - lo
    }
}
