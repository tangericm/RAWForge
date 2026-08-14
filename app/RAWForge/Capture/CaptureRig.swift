import AVFoundation
import CoreMedia
import Foundation

/// Opens one *physical* single-camera device and drives deterministic Bayer
/// capture on it.
///
/// Requesting Bayer is itself the request for determinism (#2): it forces
/// `photoQualityPrioritization = .speed`, which is separately the precondition
/// for `setExposureModeCustom` being honoured rather than overridden by fusion,
/// and it is offered only on single-camera devices, so sensor auto-switching
/// cannot arise once the device is open.
final class CaptureRig {

    enum RigError: Error, CustomStringConvertible {
        case noDevice(String)
        case noBayerFormat(String)
        case notConfigured
        case unsupported(String)
        case captureFailed(String)

        var description: String {
            switch self {
            case .noDevice(let s):      return "no device: \(s)"
            case .noBayerFormat(let s): return "no Bayer format: \(s)"
            case .notConfigured:        return "rig not configured — call configure() first"
            case .unsupported(let s):   return "unsupported: \(s)"
            case .captureFailed(let s): return "capture failed: \(s)"
            }
        }
    }

    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()

    /// Every mutation of the session happens here, serially.
    ///
    /// `AVCaptureSession` is not safe to configure from arbitrary threads, and
    /// the previous code reconfigured it on the main actor while starting it on
    /// a global queue — two threads touching one session, which is the classic
    /// source of a black preview, a stalled `startRunning`, or a capture that
    /// never fires. A dedicated serial queue is Apple's own pattern for this
    /// and makes the ordering explicit rather than incidental.
    ///
    /// The preview layer is the exception: attaching it is documented as
    /// main-thread work, and it only observes.
    private let sessionQueue = DispatchQueue(label: "com.tangericm.rawforge.session")

    private(set) var sensor: SensorCapability.Sensor?
    private(set) var device: AVCaptureDevice?
    private(set) var bayerFormat: OSType = 0
    private var activeCollector: PhotoCaptureCollector?

    /// Brings up the given sensor. Reconfiguring for a different sensor means a
    /// new session input, not a property flip — Bayer requires a single-camera
    /// device, so the sensors are sequential or nothing (#7).
    func configure(_ sensor: SensorCapability.Sensor) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try self.configureOnQueue(sensor); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func configureOnQueue(_ sensor: SensorCapability.Sensor) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [sensor.deviceType], mediaType: .video, position: .back)
        guard let dev = discovery.devices.first else {
            throw RigError.noDevice(sensor.rawValue)
        }

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw RigError.noDevice("input refused") }
        session.addInput(input)

        if session.outputs.isEmpty {
            guard session.canAddOutput(output) else { throw RigError.noDevice("output refused") }
            session.addOutput(output)
        }
        // ProRAW ships NoiseReductionApplied = 0.95, so calibrating a noise
        // model against it would be circular. Never enabled (#5).
        if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = false }
        session.commitConfiguration()

        guard let bayer = output.availableRawPhotoPixelFormatTypes
            .first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
            throw RigError.noBayerFormat(sensor.rawValue)
        }
        self.sensor = sensor
        self.device = dev
        self.bayerFormat = bayer
    }

    /// Fire-and-forget: `startRunning` blocks, so it never runs on the caller's
    /// thread. Ordering against configuration is guaranteed by the queue.
    func startSession() {
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stopSession() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Awaits the session actually running, for callers that must not fire into
    /// a session still coming up.
    func startSessionAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
    }

    /// Brings a sensor up purely so the viewfinder has something to show.
    /// Never called mid-station — framing is for between stations, when the
    /// operator is walking to the next pose.
    func prepareForFraming(_ sensor: SensorCapability.Sensor) {
        Task { [weak self] in
            guard let self else { return }
            guard (try? await self.configure(sensor)) != nil else { return }
            self.startSession()
        }
    }

    // MARK: - Deterministic parameters

    /// Locks shutter and ISO to what the protocol demands. Rails are the
    /// device's own; a request outside them is reported rather than silently
    /// clamped, because a clamped rung that reads back as requested is exactly
    /// the after-the-fact inference this app exists to eliminate (#8).
    @discardableResult
    func lockExposure(shutterSeconds: Double, iso: Float) async throws -> FrameRecord.Exposure {
        guard let d = device else { throw RigError.notConfigured }
        guard d.isExposureModeSupported(.custom) else {
            throw RigError.unsupported("this sensor does not support custom exposure")
        }
        let f = d.activeFormat
        let duration = CMTime(seconds: shutterSeconds, preferredTimescale: 1_000_000_000)
        guard CMTimeCompare(duration, f.minExposureDuration) >= 0,
              CMTimeCompare(duration, f.maxExposureDuration) <= 0 else {
            throw RigError.unsupported(String(
                format: "shutter %.6fs is outside the sensor's rails %.6f–%.6fs",
                shutterSeconds, f.minExposureDuration.seconds, f.maxExposureDuration.seconds))
        }
        guard iso >= f.minISO && iso <= f.maxISO else {
            throw RigError.unsupported(String(
                format: "ISO %.0f is outside the sensor's rails %.0f–%.0f", iso, f.minISO, f.maxISO))
        }

        try d.lockForConfiguration()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            d.setExposureModeCustom(duration: duration, iso: iso) { _ in cont.resume() }
        }
        d.unlockForConfiguration()

        // The completion handler reports when the values take effect, but the
        // device can still be converging. Firing into that window is the
        // likeliest cause of a capture the pipeline refuses.
        var spins = 0
        while d.isAdjustingExposure && spins < 100 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        return achievedExposure()
    }

    /// The Daylight lock, defined explicitly rather than inherited.
    ///
    /// #6 chose iOS 17 over 26 partly because the `.daylight` preset is not
    /// worth a floor: `deviceWhiteBalanceGains(for:)` has existed since iOS 10,
    /// so the app computes the gains it wants from a *stated* temperature and
    /// tint. A written-down number beats a named constant when the number is
    /// the thing being calibrated against.
    @discardableResult
    func lockWhiteBalance(temperature: Float = 5500, tint: Float = 0) async throws -> (set: [Float], readBack: [Float]) {
        guard let d = device else { throw RigError.notConfigured }
        guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            throw RigError.unsupported("this sensor does not support a custom white-balance gain lock")
        }
        let wanted = d.deviceWhiteBalanceGains(
            for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint))
        // Out-of-range gains raise an NSException that Swift cannot catch.
        let hi = d.maxWhiteBalanceGain
        let gains = AVCaptureDevice.WhiteBalanceGains(
            redGain:   min(max(wanted.redGain,   1.0), hi),
            greenGain: min(max(wanted.greenGain, 1.0), hi),
            blueGain:  min(max(wanted.blueGain,  1.0), hi))

        try d.lockForConfiguration()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            d.setWhiteBalanceModeLocked(with: gains) { _ in cont.resume() }
        }
        d.unlockForConfiguration()

        // The system normalises so the minimum channel is 1.0, so what was set
        // is not what reads back. Both are kept (#6).
        let back = d.deviceWhiteBalanceGains
        return ([gains.redGain, gains.greenGain, gains.blueGain],
                [back.redGain, back.greenGain, back.blueGain])
    }

    /// Locks explicit per-channel gains rather than a temperature.
    ///
    /// Item 3 needs two *deliberately extreme* and opposite settings, not two
    /// plausible ones — a small difference in gain would be indistinguishable
    /// from noise in the pixel comparison.
    @discardableResult
    func lockWhiteBalanceGains(r: Float, g: Float, b: Float) async throws -> (set: [Float], readBack: [Float]) {
        guard let d = device else { throw RigError.notConfigured }
        guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            throw RigError.unsupported("this sensor does not support a custom white-balance gain lock")
        }
        // Out-of-range gains raise an NSException that Swift cannot catch.
        let hi = d.maxWhiteBalanceGain
        let gains = AVCaptureDevice.WhiteBalanceGains(
            redGain:   min(max(r, 1.0), hi),
            greenGain: min(max(g, 1.0), hi),
            blueGain:  min(max(b, 1.0), hi))
        try d.lockForConfiguration()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            d.setWhiteBalanceModeLocked(with: gains) { _ in cont.resume() }
        }
        d.unlockForConfiguration()
        let back = d.deviceWhiteBalanceGains
        return ([gains.redGain, gains.greenGain, gains.blueGain],
                [back.redGain, back.greenGain, back.blueGain])
    }

    func achievedExposure() -> FrameRecord.Exposure {
        guard let d = device else {
            return FrameRecord.Exposure(shutterSeconds: 0, iso: 0, whiteBalanceGains: nil)
        }
        let g = d.deviceWhiteBalanceGains
        return FrameRecord.Exposure(
            shutterSeconds: d.exposureDuration.seconds,
            iso: d.iso,
            whiteBalanceGains: [g.redGain, g.greenGain, g.blueGain])
    }

    // MARK: - Capture

    /// Bayer RAW requires `videoZoomFactor == 1.0`, and the platform enforces
    /// it by **killing the process**: setting zoom away from 1.0 succeeds
    /// silently, and the violation surfaces at `capturePhoto` as an ObjC
    /// exception Swift cannot catch (#14 item 10, measured).
    ///
    /// So the invariant has to be checked here, before the call that would
    /// crash. #8 requires 2x to be unreachable rather than merely
    /// undocumented; this is where that is made true.
    private func assertZoomInvariant() throws {
        guard let d = device else { throw RigError.notConfigured }
        let z = Double(d.videoZoomFactor)
        guard z == 1.0 else {
            throw RigError.unsupported(String(
                format: "videoZoomFactor is %.3f, and a Bayer capture at anything but 1.0 "
                    + "terminates the process rather than returning an error — refusing", z))
        }
    }

    var currentZoomFactor: Double { device.map { Double($0.videoZoomFactor) } ?? 0 }

    func captureSingle() async throws -> AVCapturePhoto {
        try assertZoomInvariant()
        let settings = AVCapturePhotoSettings(rawPixelFormatType: bayerFormat)
        guard let photo = try await run(settings).first else {
            throw RigError.captureFailed("the capture returned no photo")
        }
        return photo
    }

    var maxBracketCount: Int { output.maxBracketedCapturePhotoCount }

    /// One hardware request carrying per-frame exposure. The device is not
    /// reconfigured between frames — the parameters ride with the request — so
    /// there is no convergence to wait for and the inter-frame gap is
    /// pipeline-bound.
    ///
    /// `photoQualityPrioritization` is deliberately untouched: requesting Bayer
    /// already forces `.speed`, and setting it explicitly on a bracket is the
    /// documented conflict (#14 item 1). Leaving it alone is the honest test.
    func captureBracket(_ specs: [CaptureSpec]) async throws -> [AVCapturePhoto] {
        guard let d = device else { throw RigError.notConfigured }
        try assertZoomInvariant()
        guard !specs.isEmpty else { throw RigError.captureFailed("empty capture set") }
        guard specs.count <= output.maxBracketedCapturePhotoCount else {
            throw RigError.unsupported(
                "\(specs.count) frames exceeds maxBracketedCapturePhotoCount of \(output.maxBracketedCapturePhotoCount) — use sequential")
        }
        let f = d.activeFormat
        for s in specs {
            let t = CMTime(seconds: s.shutterSeconds, preferredTimescale: 1_000_000_000)
            guard CMTimeCompare(t, f.minExposureDuration) >= 0,
                  CMTimeCompare(t, f.maxExposureDuration) <= 0,
                  s.iso >= f.minISO, s.iso <= f.maxISO else {
                throw RigError.unsupported("rung \(s.shutterLabel) ISO \(Int(s.iso)) is outside the sensor's rails")
            }
        }

        let bracket = specs.map { s in
            AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration: CMTime(seconds: s.shutterSeconds, preferredTimescale: 1_000_000_000),
                iso: s.iso)
        }
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: bayerFormat,
            processedFormat: nil,
            bracketedSettings: bracket)
        return try await run(settings)
    }

    private func run(_ settings: AVCapturePhotoSettings) async throws -> [AVCapturePhoto] {
        try await withCheckedThrowingContinuation { cont in
            let collector = PhotoCaptureCollector { [weak self] result in
                self?.activeCollector = nil
                cont.resume(with: result)
            }
            activeCollector = collector
            output.capturePhoto(with: settings, delegate: collector)
        }
    }
}

/// Gathers every photo from one capture request and resolves exactly once.
///
/// Both delegate callbacks can fire for a single request, and a bracket calls
/// the per-photo one repeatedly. Resuming a continuation twice is a hard crash,
/// so the result is delivered only from `didFinishCaptureFor`.
private final class PhotoCaptureCollector: NSObject, AVCapturePhotoCaptureDelegate {
    private var photos: [AVCapturePhoto] = []
    private var firstError: Error?
    private var finished = false
    private let done: (Result<[AVCapturePhoto], Error>) -> Void

    init(done: @escaping (Result<[AVCapturePhoto], Error>) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Recorded, not thrown: the rest of a bracket still arrives, and how
        // many frames landed is itself the result.
        if let error {
            if firstError == nil { firstError = error }
            return
        }
        photos.append(photo)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !finished else { return }
        finished = true
        if let e = error ?? firstError { done(.failure(e)) } else { done(.success(photos)) }
    }
}
