import CoreMotion
import Foundation

/// One device-motion sample, in the units CoreMotion reports them.
///
/// `t` is `CMDeviceMotion.timestamp`, which lives in the `systemUptime` domain
/// — the same monotonic clock the session header anchors to (#9). Whether it
/// shares a timebase with `AVCapturePhoto.timestamp` is #14 item 20, and is
/// answerable from these numbers rather than assumed.
struct MotionSample: Codable, Equatable {
    let t: TimeInterval
    let gx: Double, gy: Double, gz: Double
    let ax: Double, ay: Double, az: Double

    var gyroMagnitude: Double { (gx*gx + gy*gy + gz*gz).squareRoot() }
    var accelMagnitude: Double { (ax*ax + ay*ay + az*az).squareRoot() }
}

/// What the motion stream says about one window — a frame's exposure, a sensor
/// swap, or a whole station.
///
/// Motion is a **recorded observable and never a pose** (#10). Nothing here
/// estimates where the camera was; it describes how still it was held.
struct MotionSummary: Codable, Equatable {
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    let sampleCount: Int

    /// Effective rate over the window. Compared against the requested rate this
    /// answers #14 item 19 — whether sampling survives a capture in flight.
    let effectiveHz: Double
    /// The worst hole in the stream. A summary computed over a window with a
    /// large gap is describing less than it appears to.
    let worstGapSeconds: Double

    let gyroP50: Double, gyroP90: Double, gyroP99: Double, gyroMax: Double
    let accelP50: Double, accelP90: Double, accelP99: Double, accelMax: Double

    static func over(_ samples: [MotionSample], from start: TimeInterval, to end: TimeInterval) -> MotionSummary? {
        let inWindow = samples.filter { $0.t >= start && $0.t <= end }
        guard !inWindow.isEmpty else { return nil }
        let span = max(end - start, .leastNonzeroMagnitude)

        var worstGap = 0.0
        for i in 1..<max(inWindow.count, 1) where inWindow.count > 1 {
            worstGap = max(worstGap, inWindow[i].t - inWindow[i - 1].t)
        }
        let gyro = inWindow.map(\.gyroMagnitude).sorted()
        let accel = inWindow.map(\.accelMagnitude).sorted()
        func p(_ xs: [Double], _ q: Double) -> Double {
            xs[min(xs.count - 1, Int(q * Double(xs.count)))]
        }
        return MotionSummary(
            windowStart: start, windowEnd: end, sampleCount: inWindow.count,
            effectiveHz: Double(inWindow.count) / span, worstGapSeconds: worstGap,
            gyroP50: p(gyro, 0.50), gyroP90: p(gyro, 0.90), gyroP99: p(gyro, 0.99), gyroMax: gyro.last ?? 0,
            accelP50: p(accel, 0.50), accelP90: p(accel, 0.90), accelP99: p(accel, 0.99), accelMax: accel.last ?? 0)
    }
}

/// Records the IMU stream alongside the frames for the length of a station.
///
/// The README names this as one of the two things a third-party app cannot
/// give: rolling shutter and motion blur need per-frame device motion, and RAW
/// capture cannot coexist with ARKit on this platform, so the stream has to be
/// captured here or not at all.
final class MotionRecorder {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [MotionSample] = []

    let requestedHz: Double

    /// 100 Hz, because that is the ceiling and asking for more is noise.
    ///
    /// Measured: requesting 200 Hz delivered 99.4 Hz, with a raw sample
    /// interval of 10.03 ms whose median, mean and maximum were identical —
    /// a hard cap on fused device motion, not congestion. Raw
    /// `startGyroUpdates` runs faster but gives rotation rate without gravity
    /// separation or attitude, so it is a different instrument rather than a
    /// faster one.
    init(hz: Double = 100) {
        requestedHz = hz
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        lock.lock(); samples.removeAll(); lock.unlock()
        motion.deviceMotionUpdateInterval = 1 / requestedHz
        // A dedicated serial queue, not `.main`: the capture path spends long
        // stretches awaiting on the main actor, and sampling must not be
        // starved by it — that starvation would look exactly like the device
        // dropping samples under capture, which is the thing item 19 measures.
        motion.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let s = MotionSample(
                t: m.timestamp,
                gx: m.rotationRate.x, gy: m.rotationRate.y, gz: m.rotationRate.z,
                ax: m.userAcceleration.x, ay: m.userAcceleration.y, az: m.userAcceleration.z)
            self.lock.lock(); self.samples.append(s); self.lock.unlock()
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    /// Summarises a window without copying the whole buffer — a 336-frame run
    /// would otherwise re-copy tens of thousands of samples per frame.
    func summary(from start: TimeInterval, to end: TimeInterval) -> MotionSummary? {
        lock.lock(); defer { lock.unlock() }
        return MotionSummary.over(samples, from: start, to: end)
    }

    func snapshot() -> [MotionSample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// The latest sample's timestamp, for the timebase comparison (#14 item 20).
    func latestTimestamp() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return samples.last?.t
    }
}
