import AVFoundation
import Foundation

/// What one physical rear sensor reports about itself.
///
/// The platform floor (#6) gates nothing on these values — they are *reflected*
/// in the UI and *recorded* in the session header. Recording them is the
/// substitute for gating: it makes "was this shot on a device we have measured,
/// with the controls we think we had?" answerable from the files alone.
struct SensorCapability: Codable, Identifiable, Equatable {

    /// Stable token used in the log and in frame filenames (#9).
    ///
    /// Deliberately *not* the optical magnification for telephoto: 3x on an
    /// iPhone 15 Pro is 5x on a Pro Max, and #6 forbids a device allowlist, so
    /// a hardcoded "3x" would be a lie on hardware this app is required to
    /// support. Wide and ultra-wide are fixed ratios and keep the zoom naming.
    enum Sensor: String, Codable, CaseIterable {
        case wide      = "1x"
        case ultraWide = "0.5x"
        case telephoto = "tele"

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .wide:      return .builtInWideAngleCamera
            case .ultraWide: return .builtInUltraWideCamera
            case .telephoto: return .builtInTelephotoCamera
            }
        }
    }

    var id: String { sensor.rawValue }

    let sensor: Sensor

    // MARK: identity

    /// Absent when the device type is not present on this hardware at all.
    let localizedName: String?
    let uniqueID: String?
    let modelID: String?

    // MARK: the Bayer question — the one hard boundary in #6

    /// The Bayer RAW pixel format the sensor offers, if any. Nil means this
    /// sensor cannot produce the only thing the app exists to produce.
    let bayerFormat: OSType?
    var bayerFormatFourCC: String? { bayerFormat.map(fourCC) }
    var isBayerCapable: Bool { bayerFormat != nil }

    /// Every RAW format offered, Bayer or not — recorded so a sensor that
    /// offers only ProRAW is distinguishable from one offering nothing.
    let allRawFormats: [String]

    /// True when `availableRawPhotoPixelFormatTypes` stayed empty until the
    /// session was running. Apple documents the list as populated once the
    /// output is *connected* but never says whether it must be *running*;
    /// which of the two held is a fact worth carrying, not an implementation
    /// detail to paper over.
    let rawFormatsRequiredRunningSession: Bool

    /// Why this sensor is unusable, named rather than merely absent (#6:
    /// "shown as unavailable with the reason named"). Nil when usable.
    let exclusionReason: String?

    // MARK: the controls the protocol depends on

    let supportsCustomExposure: Bool
    let supportsWhiteBalanceCustomGainLock: Bool

    /// The hard ceiling on ladder depth (#8). Apple says it may be zero for
    /// some formats and publishes no values.
    let maxBracketedCapturePhotoCount: Int
    let maxWhiteBalanceGain: Float

    /// Documented as always 1.0 on single-camera devices. #6 says assert it and
    /// log loudly if it ever isn't — so both the value and the verdict are kept.
    let minAvailableVideoZoomFactor: Double
    var zoomAssertionHeld: Bool { minAvailableVideoZoomFactor == 1.0 }

    // MARK: the rails a capture set is validated against (#8)

    let minISO: Float?
    let maxISO: Float?
    let minExposureSeconds: Double?
    let maxExposureSeconds: Double?

    /// A sensor is usable for capture only if it can deliver Bayer. Everything
    /// else is reflected and recorded, never gated.
    var isUsable: Bool { isBayerCapable }

    static func absent(_ sensor: Sensor) -> SensorCapability {
        SensorCapability(
            sensor: sensor,
            localizedName: nil, uniqueID: nil, modelID: nil,
            bayerFormat: nil, allRawFormats: [],
            rawFormatsRequiredRunningSession: false,
            exclusionReason: "no \(sensor.deviceType.rawValue) on this device",
            supportsCustomExposure: false,
            supportsWhiteBalanceCustomGainLock: false,
            maxBracketedCapturePhotoCount: 0,
            maxWhiteBalanceGain: 0,
            minAvailableVideoZoomFactor: 0,
            minISO: nil, maxISO: nil,
            minExposureSeconds: nil, maxExposureSeconds: nil)
    }
}

func fourCC(_ code: OSType) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                 UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    let s = String(bytes: bytes, encoding: .ascii) ?? "?"
    return "'\(s)'(\(code))"
}
