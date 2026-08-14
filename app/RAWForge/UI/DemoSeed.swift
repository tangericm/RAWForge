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
    static var wantsTimeline: Bool { value == "timeline" }

    /// A sensor that reports what an iPhone 15 Pro's does, so the plan's
    /// arithmetic works on real numbers rather than invented ones.
    private static func sensor(_ s: SensorCapability.Sensor) -> SensorCapability {
        SensorCapability(
            sensor: s, localizedName: "demo \(s.rawValue)", uniqueID: "demo-\(s.rawValue)",
            modelID: "demo", bayerFormat: 0x62676734, allRawFormats: ["'bgg4'"],
            rawFormatsRequiredRunningSession: false, exclusionReason: nil,
            supportsCustomExposure: true, supportsWhiteBalanceCustomGainLock: true,
            maxBracketedCapturePhotoCount: 8, maxWhiteBalanceGain: 4,
            minAvailableVideoZoomFactor: 1.0, minISO: 55, maxISO: 6400,
            minExposureSeconds: 1.0 / 71429, maxExposureSeconds: 1.0)
    }

    /// A station worth drawing: a sweep and a long repeat, on two sensors, so
    /// the swap, the settle and a seam all appear.
    @MainActor static func apply(to model: CaptureModel) {
        model.report = CapabilityReport(
            device: DeviceIdentity.current(),
            sensors: [sensor(.wide), sensor(.ultraWide), sensor(.telephoto)])

        var sweep = CaptureSet.shutterSweep(
            base: CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
            stopsPerRung: 1, rungs: 7, name: "ladder-7x1stop")
        sweep.executionMode = .hardwareBracket

        var repeated = CaptureSet.repeated(
            CaptureSpec(shutterSeconds: 1.0 / 250, iso: 100), count: 16, name: "repeat-16")
        repeated.executionMode = .sequential

        model.shotList = ShotList(entries: [
            ShotListEntry(index: 0, sensor: .wide, captureSet: sweep),
            ShotListEntry(index: 1, sensor: .telephoto, captureSet: repeated),
        ], cursor: 0)
        model.poseIntent = "tripod-rigid"
        model.phase = .sessionOpen
    }
}
#endif
