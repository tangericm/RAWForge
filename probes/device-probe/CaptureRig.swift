import AVFoundation
import CoreMedia

/// Opens a *physical* single-camera device and configures it for Bayer RAW,
/// then exposes single and bracketed capture as async calls. The whole point
/// of requesting Bayer is that it forces the physical device and `.speed`, so
/// sensor auto-switching and zoom drift cannot arise (viability gate, #2).
///
/// Deliberately minimal: no preview layer, no session-preset gymnastics. The
/// probes want frames and metadata, not a viewfinder.
final class CaptureRig {

    enum RigError: Error, CustomStringConvertible {
        case noDevice(String)
        case noBayerFormat
        case notConfigured
        case captureFailed(String)

        var description: String {
            switch self {
            case .noDevice(let s):     return "no device: \(s)"
            case .noBayerFormat:       return "device offers no Bayer RAW pixel format"
            case .notConfigured:       return "rig not configured — call configure() first"
            case .captureFailed(let s): return "capture failed: \(s)"
            }
        }
    }

    let deviceType: AVCaptureDevice.DeviceType
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()

    private(set) var device: AVCaptureDevice?
    private(set) var bayerFormat: OSType = 0

    /// True when the RAW format list stayed empty until the session was running.
    /// A finding in its own right, not just an implementation detail.
    private(set) var formatNeededRunningSession = false

    /// Held strongly for the lifetime of a capture — the delegate is otherwise
    /// deallocated the moment the call returns and the callbacks never fire.
    private var activeCollector: PhotoCaptureCollector?

    init(deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera) {
        self.deviceType = deviceType
    }

    /// Discover the physical device, wire input + output, pick a Bayer format.
    func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [deviceType],
            mediaType: .video,
            position: .back)
        guard let dev = discovery.devices.first else {
            throw RigError.noDevice(String(describing: deviceType))
        }
        device = dev

        session.beginConfiguration()
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw RigError.noDevice("cannot add input") }
        session.addInput(input)

        guard session.canAddOutput(output) else { throw RigError.noDevice("cannot add output") }
        session.addOutput(output)

        // Bayer, never ProRAW. ProRAW ships NoiseReductionApplied = 0.95, which
        // is the whole reason it is disqualified (map / #5).
        if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = false }

        // Allow the highest quality the output supports, so item 1 tests the
        // real conflict rather than one we pre-empted by asking for .speed.
        output.maxPhotoQualityPrioritization = .quality

        session.commitConfiguration()

        // Pick a genuine Bayer format from what the device actually offers.
        // Apple documents this list as populated once the output is connected to
        // a session, but never says whether that session must be *running*. Try
        // before starting; if the list is empty, start and try again. Which of
        // the two worked is recorded rather than papered over — it is a fact
        // about the API that the real app's session-open path has to honour.
        bayerFormat = firstBayerFormat()
        if bayerFormat == 0 {
            session.startRunning()
            bayerFormat = firstBayerFormat()
            formatNeededRunningSession = bayerFormat != 0
        }
        guard bayerFormat != 0 else { throw RigError.noBayerFormat }
    }

    /// availableRawPhotoPixelFormatTypes imports as [OSType] — no NSNumber unwrap.
    private func firstBayerFormat() -> OSType {
        output.availableRawPhotoPixelFormatTypes
            .first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) } ?? 0
    }

    func startSession() {
        if !session.isRunning { session.startRunning() }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }

    /// A short, human-readable line describing what the device reports — the
    /// capability read that a real session-open record would carry (#6).
    func capabilityLine() -> String {
        guard let d = device else { return "device: <none>" }
        let f = d.activeFormat
        let raws = output.availableRawPhotoPixelFormatTypes
            .map { fourCC($0) + (AVCapturePhotoOutput.isBayerRAWPixelFormat($0) ? "(bayer)" : "(other)") }
            .joined(separator: " ")
        return """
        device: \(d.localizedName) · uniqueID \(d.uniqueID)
        ISO range: \(f.minISO)–\(f.maxISO) · exposure \(f.minExposureDuration.seconds)s–\(f.maxExposureDuration.seconds)s
        maxWhiteBalanceGain: \(d.maxWhiteBalanceGain)
        WB custom-gain lock supported: \(d.isLockingWhiteBalanceWithCustomDeviceGainsSupported)
        maxBracketedCapturePhotoCount: \(output.maxBracketedCapturePhotoCount)
        raw formats: \(raws)
        chosen Bayer format: \(fourCC(bayerFormat))
        RAW format list required a running session: \(formatNeededRunningSession)
        maxPhotoQualityPrioritization: \(output.maxPhotoQualityPrioritization.rawValue)
        """
    }

    // MARK: - Exposure & white balance

    func lockExposure(duration: CMTime, iso: Float) async throws {
        guard let d = device else { throw RigError.notConfigured }
        let f = d.activeFormat
        let clampedISO = min(max(iso, f.minISO), f.maxISO)
        let clampedDur = clamp(duration, f.minExposureDuration, f.maxExposureDuration)
        try d.lockForConfiguration()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            d.setExposureModeCustom(duration: clampedDur, iso: clampedISO) { _ in cont.resume() }
        }
        d.unlockForConfiguration()
    }

    /// Clamp per-channel gains into [1, maxWhiteBalanceGain] before locking —
    /// out-of-range gains raise an NSException that Swift cannot catch.
    func lockWhiteBalance(r: Float, g: Float, b: Float) async throws -> AVCaptureDevice.WhiteBalanceGains {
        guard let d = device else { throw RigError.notConfigured }
        guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            throw RigError.captureFailed("WB custom-gain lock unsupported")
        }
        let hi = d.maxWhiteBalanceGain
        var gains = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(r, 1.0), hi),
            greenGain: min(max(g, 1.0), hi),
            blueGain: min(max(b, 1.0), hi))
        try d.lockForConfiguration()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            d.setWhiteBalanceModeLocked(with: gains) { _ in cont.resume() }
        }
        d.unlockForConfiguration()
        return gains
    }

    // MARK: - Capture

    /// One Bayer RAW frame at the current locked exposure / WB.
    func captureSingle() async throws -> [AVCapturePhoto] {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: bayerFormat)
        return try await run(settings)
    }

    /// A manual-exposure Bayer RAW bracket. This is the item-1 feasibility test:
    /// if it delivers `durations.count` frames, the feared photoQualityPrioritization
    /// conflict does not block it.
    func captureBracket(durations: [CMTime], iso: Float) async throws -> [AVCapturePhoto] {
        guard let d = device else { throw RigError.notConfigured }
        let f = d.activeFormat
        let clampedISO = min(max(iso, f.minISO), f.maxISO)
        let bracket: [AVCaptureBracketedStillImageSettings] = durations.map { dur in
            AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration: clamp(dur, f.minExposureDuration, f.maxExposureDuration),
                iso: clampedISO)
        }
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: bayerFormat,
            processedFormat: nil,
            bracketedSettings: bracket)
        // Deliberately NOT touching photoQualityPrioritization — leaving it at
        // the default is the honest feasibility test. If the default already
        // conflicts with a raw bracket, the capture fails and that is the finding.
        return try await run(settings)
    }

    private func run(_ settings: AVCapturePhotoSettings) async throws -> [AVCapturePhoto] {
        try await withCheckedThrowingContinuation { cont in
            let collector = PhotoCaptureCollector { result in
                self.activeCollector = nil
                cont.resume(with: result)
            }
            self.activeCollector = collector
            output.capturePhoto(with: settings, delegate: collector)
        }
    }
}

/// Gathers every photo from one capture request and resolves once the whole
/// request finishes. `didFinishCaptureFor` fires once per request, after all
/// bracketed frames have been delivered.
private final class PhotoCaptureCollector: NSObject, AVCapturePhotoCaptureDelegate {
    private var photos: [AVCapturePhoto] = []
    private var firstError: Error?
    /// Both callbacks can fire for one request, and a bracket calls the
    /// per-photo one repeatedly. Resuming a continuation twice is a hard crash,
    /// so the result is delivered exactly once, from `didFinishCaptureFor`.
    private var finished = false
    private let done: (Result<[AVCapturePhoto], Error>) -> Void

    init(done: @escaping (Result<[AVCapturePhoto], Error>) -> Void) {
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        // A per-frame error is recorded, not thrown: the remaining frames of a
        // bracket still arrive, and how many landed is itself the item-1 result.
        if let error {
            if firstError == nil { firstError = error }
            return
        }
        photos.append(photo)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard !finished else { return }
        finished = true
        if let error = error ?? firstError {
            done(.failure(error))
        } else {
            done(.success(photos))
        }
    }
}

// MARK: - small helpers

func clamp(_ t: CMTime, _ lo: CMTime, _ hi: CMTime) -> CMTime {
    if CMTimeCompare(t, lo) < 0 { return lo }
    if CMTimeCompare(t, hi) > 0 { return hi }
    return t
}

func fourCC(_ code: OSType) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                 UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    let s = String(bytes: bytes, encoding: .ascii) ?? "?"
    return "'\(s)'(\(code))"
}
