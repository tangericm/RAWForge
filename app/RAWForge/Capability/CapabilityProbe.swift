import AVFoundation
import Foundation

/// The result of probing every rear sensor, once, at session open.
struct CapabilityReport: Codable, Equatable {
    let device: DeviceIdentity
    let sensors: [SensorCapability]

    var usableSensors: [SensorCapability] { sensors.filter(\.isUsable) }
    var excludedSensors: [SensorCapability] { sensors.filter { !$0.isUsable } }

    /// #6's one hard boundary: no Bayer format on any sensor means there is no
    /// instrument, only a worse camera. The app still launches and names what
    /// failed — that diagnostic is worth having in the field.
    var canCapture: Bool { !usableSensors.isEmpty }

    /// Any sensor whose `minAvailableVideoZoomFactor` is not 1.0 contradicts
    /// Apple's documentation for single-camera devices. #6 says log loudly.
    var zoomAssertionViolations: [SensorCapability] {
        usableSensors.filter { !$0.zoomAssertionHeld }
    }
}

/// Opens each physical rear sensor in turn and records what it reports.
///
/// Sequential by construction: Bayer RAW requires a *single-camera*
/// `AVCaptureDevice` (#7), so each sensor needs its own session configuration.
/// Virtual and multi-camera devices are never considered — they offer ProRAW
/// only, and reject `.custom` exposure outright.
enum CapabilityProbe {

    static func run() -> CapabilityReport {
        CapabilityReport(
            device: .current(),
            sensors: SensorCapability.Sensor.allCases.map(probe))
    }

    private static func probe(_ sensor: SensorCapability.Sensor) -> SensorCapability {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [sensor.deviceType],
            mediaType: .video,
            position: .back)
        guard let device = discovery.devices.first else {
            return .absent(sensor)
        }

        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        var startedSession = false
        defer { if startedSession { session.stopRunning() } }

        var failure: String?
        session.beginConfiguration()
        session.sessionPreset = .photo
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            else { failure = "session refused the device input" }

            if session.canAddOutput(output) { session.addOutput(output) }
            else { failure = failure ?? "session refused the photo output" }

            // Bayer, never ProRAW — ProRAW ships NoiseReductionApplied = 0.95,
            // which is the whole reason it is disqualified (#5).
            if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = false }
        } catch {
            failure = "could not open the device: \(error.localizedDescription)"
        }
        session.commitConfiguration()

        // Apple documents the RAW format list as populated once the output is
        // connected, but never says whether the session must also be running.
        // Try connected-only first, then running, and carry which one worked.
        var formats = output.availableRawPhotoPixelFormatTypes
        var neededRunning = false
        if formats.isEmpty && failure == nil {
            session.startRunning()
            startedSession = true
            formats = output.availableRawPhotoPixelFormatTypes
            neededRunning = !formats.isEmpty
        }

        let bayer = formats.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let format = device.activeFormat

        return SensorCapability(
            sensor: sensor,
            localizedName: device.localizedName,
            uniqueID: device.uniqueID,
            modelID: device.modelID,
            bayerFormat: bayer,
            allRawFormats: formats.map { fourCC($0) + (AVCapturePhotoOutput.isBayerRAWPixelFormat($0) ? " bayer" : " other") },
            rawFormatsRequiredRunningSession: neededRunning,
            exclusionReason: failure ?? (bayer == nil
                ? (formats.isEmpty
                    ? "sensor offers no RAW format at all"
                    : "sensor offers RAW but none of it is Bayer (ProRAW only)")
                : nil),
            supportsCustomExposure: device.isExposureModeSupported(.custom),
            supportsWhiteBalanceCustomGainLock: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            supportsLockedFocus: device.isFocusModeSupported(.locked),
            supportsCustomLensPosition: device.isLockingFocusWithCustomLensPositionSupported,
            supportsFocusPointOfInterest: device.isFocusPointOfInterestSupported,
            // Documented as -1 when the device cannot report it, which is not a
            // distance and must not be stored as one.
            minimumFocusDistanceMillimetres: device.minimumFocusDistance >= 0
                ? device.minimumFocusDistance : nil,
            // Zero would mean "no field of view", which is not a thing a camera
            // has — so it is absence, not a measurement.
            horizontalFieldOfViewDegrees: format.videoFieldOfView > 0
                ? Double(format.videoFieldOfView) : nil,
            maxBracketedCapturePhotoCount: output.maxBracketedCapturePhotoCount,
            maxWhiteBalanceGain: device.maxWhiteBalanceGain,
            minAvailableVideoZoomFactor: Double(device.minAvailableVideoZoomFactor),
            minISO: format.minISO,
            maxISO: format.maxISO,
            minExposureSeconds: format.minExposureDuration.seconds,
            maxExposureSeconds: format.maxExposureDuration.seconds)
    }
}
