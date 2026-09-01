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
/// `DispatchQueue.async` requires a sendable capture. This type is safe under
/// the ownership rule used throughout the app: callers use it from the main
/// actor, while session topology and start/stop operations are serialized on
/// `sessionQueue`. Configuration publishes its state only before resuming its
/// checked continuation. The unchecked conformance documents that boundary;
/// it does not make arbitrary concurrent use supported.
final class CaptureRig: @unchecked Sendable {

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
        let began = ProcessInfo.processInfo.systemUptime

        // Framing prepares the next set's sensor before the operator presses
        // capture. `beginNextSet` asks for that sensor again because it cannot
        // assume the asynchronous preview preparation has finished; once both
        // calls serialize here, however, rebuilding the same live graph is
        // pure waste and costs hundreds of milliseconds on real hardware.
        //
        // Check the graph as well as our label. If another owner ever removes
        // an input or output, the label alone must not turn a broken session
        // into a successful no-op.
        if self.sensor == sensor,
           let device,
           bayerFormat != 0,
           session.inputs.contains(where: {
               ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID
           }),
           session.outputs.contains(where: { $0 === output }) {
            logTrace(.rig, String(format: "%@ already configured — reused in %.1f ms",
                                  sensor.rawValue,
                                  (ProcessInfo.processInfo.systemUptime - began) * 1_000))
            return
        }

        logInfo(.rig, "configuring \(sensor.rawValue)")
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [sensor.deviceType], mediaType: .video, position: .back)
        guard let dev = discovery.devices.first else {
            logError(.rig, "no device of type \(sensor.deviceType.rawValue) on the back")
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
            logError(.rig, "\(sensor.rawValue) offers no Bayer RAW format — available: "
                     + output.availableRawPhotoPixelFormatTypes.map(fourCC).joined(separator: ", "))
            throw RigError.noBayerFormat(sensor.rawValue)
        }
        self.sensor = sensor
        self.device = dev
        self.bayerFormat = bayer
        logInfo(.rig, String(format: "%@ ready in %.0f ms · %@ · bracket max %d · zoom %.3f",
                             sensor.rawValue,
                             (ProcessInfo.processInfo.systemUptime - began) * 1000,
                             fourCC(bayer), output.maxBracketedCapturePhotoCount,
                             Double(dev.videoZoomFactor)))
    }

    /// Fire-and-forget: `startRunning` blocks, so it never runs on the caller's
    /// thread. Ordering against configuration is guaranteed by the queue.
    func startSession() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            let t = ProcessInfo.processInfo.systemUptime
            self.session.startRunning()
            logInfo(.rig, String(format: "session running after %.0f ms",
                                 (ProcessInfo.processInfo.systemUptime - t) * 1000))
        }
    }

    func stopSession() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            logInfo(.rig, "session stopped")
        }
    }

    /// Awaits the session actually running, for callers that must not fire into
    /// a session still coming up.
    func startSessionAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning {
                    let t = ProcessInfo.processInfo.systemUptime
                    self.session.startRunning()
                    logInfo(.rig, String(format: "session running after %.0f ms (awaited)",
                                         (ProcessInfo.processInfo.systemUptime - t) * 1000))
                }
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
            let e = RigError.unsupported(String(
                format: "shutter %.6fs is outside the sensor's rails %.6f–%.6fs",
                shutterSeconds, f.minExposureDuration.seconds, f.maxExposureDuration.seconds))
            logError(.rig, e.description)
            throw e
        }
        guard iso >= f.minISO && iso <= f.maxISO else {
            let e = RigError.unsupported(String(
                format: "ISO %.0f is outside the sensor's rails %.0f–%.0f", iso, f.minISO, f.maxISO))
            logError(.rig, e.description)
            throw e
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
        let achieved = achievedExposure()
        // The spin count is the number worth having: a capture that fails with
        // -11800 almost always fired into a device still converging, and this
        // says whether it had settled or ran out of patience.
        if spins >= 100 {
            logWarn(.rig, String(format: "exposure still converging after 500 ms — fired anyway "
                                 + "(asked %.6fs ISO %.0f, device reports %.6fs ISO %.0f)",
                                 shutterSeconds, iso, achieved.shutterSeconds, achieved.iso))
        } else {
            logTrace(.rig, String(format: "exposure locked in %d spin(s) — asked %.6fs ISO %.0f, "
                                  + "device %.6fs ISO %.0f", spins, shutterSeconds, iso,
                                  achieved.shutterSeconds, achieved.iso))
        }
        return achieved
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

    #if DEBUG
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
    #endif

    // MARK: - Focus (#18)

    /// A focus decision with everything already worked out: the point mapped
    /// into *this* sensor's frame, and any exact position carried over from an
    /// earlier lock on this same sensor.
    ///
    /// The rig deliberately does no resolving of its own. Which sensor a point
    /// came from and whether a stored position is still applicable are facts
    /// about the station, and a rig that guessed at them would be inventing
    /// context it does not have.
    struct FocusResolution {
        var intent: FocusPlan.Intent = .automatic

        /// Already in `AVCaptureDevice` coordinates, already mapped.
        var point: CGPoint?
        var mappedFrom: String?

        /// A lens position measured earlier **on this sensor**, to be
        /// re-commanded exactly rather than re-hunted. Only ever set by a
        /// caller that knows the sensor has not changed.
        var restore: Float?

        var note: String?
    }

    /// How long autofocus is given before the app stops waiting and records
    /// that it did. Generous rather than tight: a focus sweep in low light runs
    /// past a second, and the failure mode this guards against is a station
    /// hanging at the pose, not a slow lens.
    static let focusConvergenceTimeout: TimeInterval = 2.0

    /// Puts the lens where the station says it should be, and reports what
    /// actually happened.
    ///
    /// **Never throws.** #6 makes Bayer the only hard boundary, so a sensor that
    /// cannot lock focus still shoots — it shoots with a note saying focus was
    /// not held, which is a fact a reader can act on. Aborting a station over it
    /// would destroy frames to protect a property the frames could simply have
    /// been annotated with.
    func applyFocus(_ r: FocusResolution) async -> FrameRecord.Focus {
        let began = ProcessInfo.processInfo.systemUptime
        var notes: [String] = r.note.map { [$0] } ?? []

        func finish(_ acquisition: String, converged: Bool?) -> FrameRecord.Focus {
            let d = device
            return FrameRecord.Focus(
                intent: r.intent.label,
                acquisition: acquisition,
                mode: d.map { Self.name(of: $0.focusMode) } ?? "none",
                lensPosition: d?.lensPosition,
                pointOfInterest: r.point.map { [Double($0.x), Double($0.y)] },
                pointMappedFromSensor: r.mappedFrom,
                converged: converged,
                acquisitionSeconds: ProcessInfo.processInfo.systemUptime - began,
                minimumFocusDistanceMillimetres: d.flatMap {
                    $0.minimumFocusDistance >= 0 ? $0.minimumFocusDistance : nil
                },
                note: notes.isEmpty ? nil : notes.joined(separator: "; "))
        }

        guard let d = device else {
            notes.append("rig not configured")
            return finish("notLocked", converged: nil)
        }

        // An exact position — either restored from this sensor's own earlier
        // lock, or commanded by the operator. Both are the same operation; they
        // differ only in who chose the number, which is worth recording.
        let exact: (value: Float, acquisition: String)? = {
            if let p = r.restore { return (p, "restored") }
            if let p = r.intent.lensPosition { return (Float(p), "commanded") }
            return nil
        }()

        if let exact {
            if d.isLockingFocusWithCustomLensPositionSupported {
                let clamped = min(max(exact.value, 0), 1)
                if clamped != exact.value {
                    notes.append(String(format: "lens position %.3f clamped to %.3f",
                                        exact.value, clamped))
                }
                do {
                    try d.lockForConfiguration()
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        d.setFocusModeLocked(lensPosition: clamped) { _ in c.resume() }
                    }
                    d.unlockForConfiguration()
                    logTrace(.rig, String(format: "focus %@ at %.4f", exact.acquisition, clamped))
                    return finish(exact.acquisition, converged: true)
                } catch {
                    notes.append("could not lock the device for configuration: \(error)")
                    return finish("notLocked", converged: nil)
                }
            }
            // The position cannot be commanded, so autofocus below is the only
            // route left. Saying so matters: a "restored" frame and a re-hunted
            // one are not the same claim, and silently substituting one for the
            // other is how a log starts lying.
            notes.append("this sensor cannot be given a lens position — "
                         + "autofocused instead of \(exact.acquisition)")
        }

        // Autofocus, aimed if the operator aimed it, then frozen.
        do {
            try d.lockForConfiguration()
            if let pt = r.point {
                if d.isFocusPointOfInterestSupported {
                    d.focusPointOfInterest = CGPoint(x: min(max(pt.x, 0), 1),
                                                     y: min(max(pt.y, 0), 1))
                } else {
                    notes.append("this sensor cannot aim autofocus — the point was ignored")
                }
            }
            if d.isFocusModeSupported(.autoFocus) {
                d.focusMode = .autoFocus
            } else {
                notes.append("this sensor does not support a one-shot autofocus")
            }
            d.unlockForConfiguration()
        } catch {
            notes.append("could not lock the device for configuration: \(error)")
            return finish("notLocked", converged: nil)
        }

        // `.autoFocus` is documented to run once and revert to locked, but the
        // revert is not instantaneous and firing into a moving lens is exactly
        // the drift this ticket exists to remove.
        let deadline = began + Self.focusConvergenceTimeout
        while d.isAdjustingFocus && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let converged = !d.isAdjustingFocus
        if !converged {
            notes.append(String(format: "autofocus had not converged after %.1f s — locked anyway",
                                Self.focusConvergenceTimeout))
            logWarn(.rig, "autofocus did not converge before the timeout — locking where it stands")
        }

        guard d.isFocusModeSupported(.locked) else {
            notes.append("this sensor cannot hold focus — it may drift across the set")
            logWarn(.rig, "\(sensor?.rawValue ?? "?") cannot lock focus; frames will say so")
            return finish("notLocked", converged: converged)
        }
        do {
            try d.lockForConfiguration()
            d.focusMode = .locked
            d.unlockForConfiguration()
        } catch {
            notes.append("could not freeze focus: \(error)")
            return finish("notLocked", converged: converged)
        }
        logTrace(.rig, String(format: "focus locked at %.4f%@ (converged: %@)",
                              d.lensPosition, r.point == nil ? "" : " on a point",
                              converged ? "yes" : "no"))
        return finish("autofocused", converged: converged)
    }

    /// Drives the lens directly while the operator is dragging a slider.
    ///
    /// Deliberately not `applyFocus`: that awaits a completion handler and
    /// builds a record, and neither is wanted sixty times a second. Nothing
    /// here is recorded, because nothing here is a capture — this exists purely
    /// so the number under the slider means something to the person setting it.
    /// What ends up in the log is whatever `applyFocus` commands at the pose.
    func previewLensPosition(_ p: Float) {
        guard let d = device, d.isLockingFocusWithCustomLensPositionSupported,
              (try? d.lockForConfiguration()) != nil else { return }
        d.setFocusModeLocked(lensPosition: min(max(p, 0), 1), completionHandler: nil)
        d.unlockForConfiguration()
    }

    /// The active format's horizontal field of view, which is what makes a
    /// focus point transferable between sensors at all.
    var fieldOfViewDegrees: Double? {
        guard let d = device, d.activeFormat.videoFieldOfView > 0 else { return nil }
        return Double(d.activeFormat.videoFieldOfView)
    }

    var currentLensPosition: Float? { device?.lensPosition }

    static func name(of mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked:              return "locked"
        case .autoFocus:           return "autoFocus"
        case .continuousAutoFocus: return "continuousAutoFocus"
        @unknown default:          return "unknown(\(mode.rawValue))"
        }
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
            let e = RigError.unsupported(String(
                format: "videoZoomFactor is %.3f, and a Bayer capture at anything but 1.0 "
                    + "terminates the process rather than returning an error — refusing", z))
            logError(.rig, e.description)
            throw e
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

    /// How a capture set was split across hardware requests. `[8, 8]` for a
    /// 16-frame set on a sensor with a ceiling of 8; a single element means it
    /// fitted in one request.
    typealias BracketRun = [Int]

    /// A pause between hardware requests — margin, not a measured threshold.
    ///
    /// The actual fix for back-to-back requests was releasing the previous
    /// request's photos before issuing the next. Holding sixteen 48 MP Bayer
    /// buffers while asking for eight more returns `-11800 / -12686` after
    /// about 14 ms, every frame of it, immediately: the same exhaustion the
    /// sequential path hit before it began streaming frames to disk instead of
    /// holding them.
    ///
    /// Measured on an iPhone 15 Pro once the release was in place: 0.05, 0.10,
    /// 0.15 and 0.25 s each delivered 16 of 16, and wall clock barely moved
    /// between them — the seam is dominated by the pipeline's own recovery
    /// (~0.5 s), not by this. So **0.25 s is a choice**: the failure it guards
    /// against costs a whole station, and in a real run the caller is writing
    /// 10 MB and computing a full-frame histogram per frame inside this window
    /// anyway.
    static let interRequestSettle: TimeInterval = 0.25

    /// Fires a capture set as hardware brackets, splitting it across as many
    /// requests as the sensor's ceiling demands.
    ///
    /// One request carries per-frame exposure and the device is not
    /// reconfigured between frames — the parameters ride with the request — so
    /// there is no convergence to wait for and the inter-frame gap is
    /// pipeline-bound. That is the whole reason to prefer a bracket, and it is
    /// worth keeping for a set longer than the ceiling.
    ///
    /// **A set past the ceiling used to abort the station.** That was wrong
    /// twice over: the ceiling is knowable before anything fires, so nothing
    /// was learned by discovering it at frame nine; and falling back to
    /// sequential would have changed the timing of *every* frame, not just the
    /// ones past the boundary. Splitting keeps bracket timing within each chunk
    /// and confines the cost to the seams — which are recorded, so a reader can
    /// see exactly where they fall.
    ///
    /// `photoQualityPrioritization` is deliberately untouched: requesting Bayer
    /// already forces `.speed`, and setting it explicitly on a bracket is the
    /// documented conflict (#14 item 1). Leaving it alone is the honest test.
    ///
    /// Photos are handed to `bank` request by request and released before the
    /// next request is issued. That is not tidiness: holding sixteen 48 MP
    /// Bayer buffers while asking for more is what exhausts the pipeline, and
    /// the caller writes each frame to disk as it arrives anyway.
    func captureBracket(_ specs: [CaptureSpec],
                        bank: (AVCapturePhoto, CaptureSpec) throws -> Void) async throws -> BracketRun {
        guard let d = device else { throw RigError.notConfigured }
        try assertZoomInvariant()
        guard !specs.isEmpty else { throw RigError.captureFailed("empty capture set") }

        let ceiling = output.maxBracketedCapturePhotoCount
        guard ceiling > 0 else {
            throw RigError.unsupported(
                "this sensor reports a hardware bracket ceiling of 0 — use sequential")
        }

        // Rails are checked across the whole set before any of it fires, so a
        // set that cannot run does not run half way.
        let f = d.activeFormat
        for s in specs {
            let t = CMTime(seconds: s.shutterSeconds, preferredTimescale: 1_000_000_000)
            guard CMTimeCompare(t, f.minExposureDuration) >= 0,
                  CMTimeCompare(t, f.maxExposureDuration) <= 0,
                  s.iso >= f.minISO, s.iso <= f.maxISO else {
                throw RigError.unsupported("rung \(s.shutterLabel) ISO \(Int(s.iso)) is outside the sensor's rails")
            }
        }

        let chunks = stride(from: 0, to: specs.count, by: ceiling).map {
            Array(specs[$0 ..< Swift.min($0 + ceiling, specs.count)])
        }
        if chunks.count > 1 {
            logInfo(.capture, "\(specs.count) frames exceeds this sensor's bracket ceiling of "
                    + "\(ceiling) — firing as \(chunks.count) requests of "
                    + chunks.map { "\($0.count)" }.joined(separator: "+"))
        }

        for (i, chunk) in chunks.enumerated() {
            if i > 0 {
                try await Task.sleep(nanoseconds: UInt64(Self.interRequestSettle * 1_000_000_000))
            }
            let bracket = chunk.map { s in
                AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: CMTime(seconds: s.shutterSeconds, preferredTimescale: 1_000_000_000),
                    iso: s.iso)
            }
            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: bayerFormat,
                processedFormat: nil,
                bracketedSettings: bracket)
            let delivered = try await run(settings)
            guard delivered.count == chunk.count else {
                throw RigError.captureFailed(
                    "request \(i + 1) of \(chunks.count) returned \(delivered.count) "
                    + "of \(chunk.count) frames")
            }
            // Written and released here, before the next request is issued.
            for (photo, spec) in zip(delivered, chunk) { try bank(photo, spec) }
        }
        return chunks.map(\.count)
    }

    private func run(_ settings: AVCapturePhotoSettings) async throws -> [AVCapturePhoto] {
        let began = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { cont in
            let collector = PhotoCaptureCollector { [weak self] result in
                self?.activeCollector = nil
                let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
                switch result {
                case .success(let photos):
                    logTrace(.capture, String(format: "request delivered %d photo(s) in %.0f ms",
                                              photos.count, ms))
                case .failure(let error):
                    logError(.capture, String(format: "request failed after %.0f ms — %@",
                                              ms, String(describing: error)))
                }
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
            logError(.capture, "photo \(photos.count + 1) of this request failed — \(error)")
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
