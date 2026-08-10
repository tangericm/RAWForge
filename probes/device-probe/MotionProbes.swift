import CoreMotion
import AVFoundation
import CoreMedia
import Foundation

/// Items 21, 19 and 20. One CoreMotion rig answers all three: what stillness
/// actually reads (21), whether sampling survives a capture (19), and whether
/// motion and capture share a timebase (20).
@MainActor
final class MotionProbes {
    let rig: CaptureRig
    let log: ProbeLog
    private let motion = CMMotionManager()
    private let sampleHz = 100.0

    init(rig: CaptureRig, log: ProbeLog) {
        self.rig = rig
        self.log = log
    }

    // MARK: item 21 — what do a tripod and a handheld hold read?

    /// Records over a fixed window and reports percentiles. Run once per mounting
    /// condition (tripod-rigid, tripod-soft, handheld) and label each in the paste.
    func probeStillness(seconds: Double = 4.0) async {
        log.section("Item 21 — stillness distribution (label the mounting condition)")
        guard motion.isDeviceMotionAvailable else { log.log("device motion unavailable"); return }

        var gyroMag: [Double] = []
        var accelMag: [Double] = []
        let samples = await collect(seconds: seconds) { m in
            gyroMag.append(magnitude(m.rotationRate))
            accelMag.append(magnitude(m.userAcceleration))
        }
        log.log("collected \(samples) samples over \(seconds)s (~\(Int(Double(samples)/seconds)) Hz effective)")
        log.log("gyro |rad/s|  " + percentiles(gyroMag))
        log.log("accel |g|     " + percentiles(accelMag))
        log.log("→ the stillness gate's threshold comes from these; a threshold on a mean fires on the tail")
    }

    // MARK: item 19 — does sampling survive a capture in flight?

    func probeSamplingUnderCapture() async {
        log.section("Item 19 — CoreMotion sampling during a RAW capture")

        // Baseline: sampling with nothing else happening.
        let base = await measureRate(seconds: 2.0, duringCapture: false)
        log.log("baseline: \(base.hz) Hz effective · worst gap \(base.maxGapMs) ms over \(base.count) samples")

        // Under load: fire a capture partway through the window.
        let load = await measureRate(seconds: 2.0, duringCapture: true)
        log.log("during capture: \(load.hz) Hz effective · worst gap \(load.maxGapMs) ms over \(load.count) samples")

        log.log("→ if the effective rate sags or the worst gap balloons under capture, the per-frame")
        log.log("  motion summary is untrustworthy and the abort trigger fires on sampling artefacts.")
    }

    // MARK: item 20 — do motion and capture share a timebase?

    func probeTimebase() async {
        log.section("Item 20 — CoreMotion vs AVCapture timebase")
        guard motion.isDeviceMotionAvailable else { log.log("device motion unavailable"); return }

        motion.deviceMotionUpdateInterval = 1.0 / sampleHz
        motion.startDeviceMotionUpdates(to: .main) { _, _ in }
        defer { motion.stopDeviceMotionUpdates() }

        do {
            let iso = rig.device?.activeFormat.minISO ?? 100
            try await rig.lockExposure(duration: CMTime(value: 1, timescale: 125), iso: iso)
            let photos = try await rig.captureSingle()

            let uptimeNow = ProcessInfo.processInfo.systemUptime
            let motionTS = motion.deviceMotion?.timestamp ?? .nan
            let photoTS = photos.first?.timestamp ?? .invalid

            log.log("photo.timestamp (CMTime): \(photoTS.seconds) s  (timescale \(photoTS.timescale))")
            log.log("latest CMDeviceMotion.timestamp: \(motionTS) s  (systemUptime domain)")
            log.log("ProcessInfo.systemUptime now: \(uptimeNow) s")
            log.log("→ CMDeviceMotion.timestamp and systemUptime are both mach_absolute_time-derived.")
            log.log("  If photo.timestamp.seconds sits on the same scale (within the capture latency),")
            log.log("  a motion sample can be placed in a frame's exposure window without a guessed offset.")
            log.log("  Record the three numbers; the offset between them is the finding.")
        } catch {
            log.log("FAILED — \(error)")
        }
    }

    // MARK: collection primitives

    private struct Rate { let hz: Int; let maxGapMs: Int; let count: Int }

    private func measureRate(seconds: Double, duringCapture: Bool) async -> Rate {
        var stamps: [TimeInterval] = []
        // Kick a capture off midway if asked; do not await it inside the sampler.
        if duringCapture {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 0.4 * 1_000_000_000))
                _ = try? await self.rig.captureSingle()
            }
        }
        let count = await collect(seconds: seconds) { m in stamps.append(m.timestamp) }
        var maxGap = 0.0
        for i in 1..<max(stamps.count, 1) where stamps.count > 1 {
            maxGap = max(maxGap, stamps[i] - stamps[i - 1])
        }
        let hz = seconds > 0 ? Int(Double(count) / seconds) : 0
        return Rate(hz: hz, maxGapMs: Int(maxGap * 1000), count: count)
    }

    /// Runs device-motion updates for `seconds`, calling `each` per sample, and
    /// returns the sample count. Uses a serial queue so appends are race-free.
    private func collect(seconds: Double, each: @escaping (CMDeviceMotion) -> Void) async -> Int {
        guard motion.isDeviceMotionAvailable else { return 0 }
        motion.deviceMotionUpdateInterval = 1.0 / sampleHz
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1

        var n = 0
        motion.startDeviceMotionUpdates(to: q) { m, _ in
            guard let m else { return }
            n += 1
            each(m)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        motion.stopDeviceMotionUpdates()
        return n
    }
}

// MARK: - math

private func magnitude(_ r: CMRotationRate) -> Double {
    (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
}
private func magnitude(_ a: CMAcceleration) -> Double {
    (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
}

private func percentiles(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "<no samples>" }
    let s = xs.sorted()
    func p(_ q: Double) -> Double { s[min(s.count - 1, Int(q * Double(s.count)))] }
    return String(format: "p50 %.5f · p90 %.5f · p99 %.5f · max %.5f",
                  p(0.50), p(0.90), p(0.99), s.last!)
}
