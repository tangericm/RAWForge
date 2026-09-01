#if DEBUG
import Foundation

/// Seeds a plausible station so the planning screens can be looked at on a
/// simulator.
///
/// A simulator has no camera, so `canCapture` is false, so no shot list can be
/// built, so the Plan sheet is unreachable — which means every UI change to it
/// would otherwise ship having only ever been compiled, never seen. This makes
/// the screens reachable without a phone.
///
/// Debug-only and reached only through an environment variable, so it cannot
/// appear in a real run:
///
///     SIMCTL_CHILD_RAWFORGE_DEMO=1 xcrun simctl launch <sim> com.tangericm.rawforge
enum DemoSeed {

    static var value: String? { ProcessInfo.processInfo.environment["RAWFORGE_DEMO"] }
    static var isRequested: Bool { value != nil }
    /// `RAWFORGE_DEMO=timeline` opens the timeline directly, which is otherwise
    /// two taps deep and unreachable without a camera.
    static var wantsTimeline: Bool { value == "timeline" || value == "single" }
    /// `RAWFORGE_DEMO=single` fakes a phone with one rear camera — an SE — so
    /// the parts of the interface that should collapse can be seen collapsing.
    static var wantsSingleSensor: Bool { value == "single" }
    /// `RAWFORGE_DEMO=focus` opens the focus pre-flight, which is otherwise
    /// three taps deep behind a shot list a simulator cannot build. The preview
    /// is black without a camera, but the layout, the mode picker and the
    /// cross-sensor mapping are all real.
    static var wantsFocus: Bool { value == "focus" || value == "focus-point" }

    /// A sensor that reports what an iPhone 15 Pro's does, so the plan's
    /// arithmetic works on real numbers rather than invented ones.
    private static func sensor(_ s: SensorCapability.Sensor) -> SensorCapability {
        SensorCapability(
            sensor: s, localizedName: "demo \(s.rawValue)", uniqueID: "demo-\(s.rawValue)",
            modelID: "demo", bayerFormat: 0x62676734, allRawFormats: ["'bgg4'"],
            rawFormatsRequiredRunningSession: false, exclusionReason: nil,
            supportsCustomExposure: true, supportsWhiteBalanceCustomGainLock: true,
            supportsLockedFocus: true, supportsCustomLensPosition: true,
            supportsFocusPointOfInterest: true,
            // Approximate, and only ever used to draw a demo. Real values come
            // from the probe on real hardware; these exist so the focus screens
            // have three genuinely different fields of view to move a point
            // between rather than three copies of one number.
            minimumFocusDistanceMillimetres: focusDistance(s),
            horizontalFieldOfViewDegrees: fieldOfView(s),
            maxBracketedCapturePhotoCount: 8, maxWhiteBalanceGain: 4,
            minAvailableVideoZoomFactor: 1.0, minISO: 55, maxISO: 6400,
            minExposureSeconds: 1.0 / 71429, maxExposureSeconds: 1.0)
    }

    private static func fieldOfView(_ s: SensorCapability.Sensor) -> Double {
        switch s {
        case .ultraWide: return 106
        case .wide:      return 69
        case .telephoto: return 25
        }
    }

    private static func focusDistance(_ s: SensorCapability.Sensor) -> Int {
        switch s {
        case .ultraWide: return 20
        case .wide:      return 120
        case .telephoto: return 400
        }
    }

    /// A focus plan with something in it, so the pre-flight opens on a real
    /// state rather than three defaults. `focus` shows a hand-set lens
    /// position; `focus-point` shows a tapped point on the wide, which is what
    /// makes the cross-sensor mapping offer appear on the other sensor.
    @MainActor static func applyFocus(to model: CaptureModel) {
        switch value {
        case "focus":       model.station.focusPlan[.wide] = .manual(lensPosition: 0.42)
        // Seeded on the *telephoto* so the screen opens on the wide with the
        // mapping on offer — the offer only appears on a sensor still set to
        // automatic, so seeding the wide would have hidden the thing this
        // demo exists to show.
        case "focus-point": model.station.focusPlan[.telephoto] = .point(x: 0.35, y: 0.42)
        default:            break
        }
    }

    /// A station worth drawing: a sweep and a long repeat, on two sensors, so
    /// the swap, the settle and a seam all appear.
    @MainActor static func apply(to model: CaptureModel) {
        model.report = wantsSingleSensor
            ? CapabilityReport(device: DeviceIdentity.current(),
                               sensors: [sensor(.wide), .absent(.ultraWide), .absent(.telephoto)])
            : CapabilityReport(device: DeviceIdentity.current(),
                               sensors: [sensor(.wide), sensor(.ultraWide), sensor(.telephoto)])

        var sweep = CaptureSet.shutterSweep(
            base: CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
            stopsPerRung: 1, rungs: 7, name: "ladder-7x1stop")
        sweep.executionMode = .hardwareBracket

        var repeated = CaptureSet.repeated(
            CaptureSpec(shutterSeconds: 1.0 / 250, iso: 100), count: 16, name: "repeat-16")
        repeated.executionMode = .sequential

        model.station.shotList = ShotList(entries: wantsSingleSensor
            ? [ShotListEntry(index: 0, sensor: .wide, captureSet: sweep),
               ShotListEntry(index: 1, sensor: .wide, captureSet: repeated)]
            : [ShotListEntry(index: 0, sensor: .wide, captureSet: sweep),
               ShotListEntry(index: 1, sensor: .telephoto, captureSet: repeated)],
            cursor: 0)
        model.station.poseIntent = "tripod-rigid"
        model.station.phase = .sessionOpen
        applyFocus(to: model)
    }
}
#endif
