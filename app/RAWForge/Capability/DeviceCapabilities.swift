import Foundation

/// What the probe's raw numbers *mean* for what can be shot.
///
/// The per-sensor table answers "what does this sensor report". It does not
/// answer the question actually being asked at the bench, which is "what can I
/// do with this phone" — and the gap between the two is arithmetic nobody
/// should be doing in their head. A `maxBracketedCapturePhotoCount` of 8 is a
/// number; "a ladder past 8 rungs has to run sequentially" is the constraint.
///
/// Nothing here is a judgement about whether the device is good enough. #6
/// gates on exactly one thing — Bayer or no instrument — and everything else is
/// reflected. This is reflection, phrased in the units the operator works in.
extension CapabilityReport {

    struct Capability: Identifiable {
        let id = UUID()
        let headline: String
        let detail: String
        /// True when this is a limit worth planning around rather than a plain
        /// statement of what works.
        let isConstraint: Bool
    }

    /// The deepest ladder that fires as one hardware request on *every* usable
    /// sensor. A shot list spanning sensors is bounded by the smallest, which
    /// is the number that actually binds a station.
    var sharedBracketCeiling: Int {
        usableSensors.map(\.maxBracketedCapturePhotoCount).min() ?? 0
    }

    var deepestBracketCeiling: Int {
        usableSensors.map(\.maxBracketedCapturePhotoCount).max() ?? 0
    }

    /// The union of every usable sensor's rails. A rung outside this cannot be
    /// shot anywhere on this device; one inside it may still be dropped on a
    /// particular sensor, which is what per-sensor validation is for.
    var shutterRange: (min: Double, max: Double)? {
        let lows = usableSensors.compactMap(\.minExposureSeconds)
        let highs = usableSensors.compactMap(\.maxExposureSeconds)
        guard let lo = lows.min(), let hi = highs.max() else { return nil }
        return (lo, hi)
    }

    var isoRange: (min: Float, max: Float)? {
        let lows = usableSensors.compactMap(\.minISO)
        let highs = usableSensors.compactMap(\.maxISO)
        guard let lo = lows.min(), let hi = highs.max() else { return nil }
        return (lo, hi)
    }

    /// Whether the sensors disagree enough that one authored ladder will not
    /// suit all of them — which is the entire reason per-sensor EV offsets
    /// exist, and worth saying before someone wonders why a rung vanished.
    var sensorsDisagreeOnRails: Bool {
        let ceilings = Set(usableSensors.compactMap(\.maxISO))
        let floors = Set(usableSensors.compactMap(\.minExposureSeconds))
        return ceilings.count > 1 || floors.count > 1
    }

    private static func shutterLabel(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.0f s", seconds)
                     : "1/\(Int((1 / seconds).rounded()))"
    }

    /// The bench's headline list: what this phone can be asked to do.
    var capabilities: [Capability] {
        guard canCapture else {
            return [Capability(
                headline: "No Bayer sensor",
                detail: "Undemosaiced Bayer RAW is the only thing this app produces, and no "
                    + "sensor here offers it. Capture is refused rather than downgraded.",
                isConstraint: true)]
        }

        var out: [Capability] = []

        let formats = Set(usableSensors.compactMap(\.bayerFormatFourCC))
        out.append(Capability(
            headline: "\(usableSensors.count) of \(sensors.count) sensors deliver Bayer",
            detail: usableSensors.map { $0.sensor.rawValue }.joined(separator: ", ")
                + " · " + formats.sorted().joined(separator: ", "),
            isConstraint: false))

        if sharedBracketCeiling > 0 {
            let shared = sharedBracketCeiling, deepest = deepestBracketCeiling
            out.append(Capability(
                headline: "Ladders up to \(shared) rungs fire as one bracket",
                detail: shared == deepest
                    ? "Longer sets still run, one exposure lock per rung — unbounded in length, "
                      + "but each rung pays a settle."
                    : "That is the smallest ceiling across the sensors; the deepest is \(deepest). "
                      + "A set spanning sensors is bound by the smallest. Longer sets run "
                      + "sequentially, unbounded but paying a settle per rung.",
                isConstraint: false))
        }

        if let s = shutterRange {
            out.append(Capability(
                headline: "Shutter \(Self.shutterLabel(s.min)) to \(Self.shutterLabel(s.max))",
                detail: "Across all usable sensors. A rung outside this cannot be shot anywhere "
                    + "on this device and is dropped rather than clamped.",
                isConstraint: false))
        }

        if let i = isoRange {
            let digital = i.min * 8.5
            out.append(Capability(
                headline: String(format: "ISO %.0f to %.0f", i.min, i.max),
                detail: String(format: "Past roughly %.0f the gain is digital rather than "
                               + "analogue, so a ladder climbing in ISO beyond that buys "
                               + "nothing real. Bracket with shutter instead.", digital),
                isConstraint: false))
        }

        let noCustom = usableSensors.filter { !$0.supportsCustomExposure }
        if noCustom.isEmpty {
            out.append(Capability(
                headline: "Exposure and white balance can both be locked",
                detail: "Shutter, ISO and per-channel white-balance gains are all set from the "
                    + "protocol rather than metered from the scene.",
                isConstraint: false))
        } else {
            out.append(Capability(
                headline: "Custom exposure is unavailable on "
                    + noCustom.map { $0.sensor.rawValue }.joined(separator: ", "),
                detail: "A protocol cannot be enforced on those sensors — the device decides "
                    + "the exposure, which is the thing this app exists to prevent.",
                isConstraint: true))
        }

        if sensorsDisagreeOnRails {
            out.append(Capability(
                headline: "The sensors do not share rails",
                detail: "One authored ladder will not suit all of them. That is what a "
                    + "per-sensor EV offset is for; without one, rungs outside a given "
                    + "sensor's range are dropped and recorded.",
                isConstraint: true))
        }

        let violations = zoomAssertionViolations
        out.append(Capability(
            headline: violations.isEmpty
                ? "Zoom is locked at 1.0, as required"
                : "Zoom does not rest at 1.0 on "
                    + violations.map { $0.sensor.rawValue }.joined(separator: ", "),
            detail: violations.isEmpty
                ? "Bayer capture demands exactly 1.0, and the platform enforces it by killing "
                  + "the process rather than returning an error. The app refuses before that call."
                : "Apple documents this as always 1.0 on single-camera devices. It is not, here, "
                  + "and a capture at anything else terminates the process — so those sensors "
                  + "are refused at the last moment rather than trusted.",
            isConstraint: !violations.isEmpty))

        return out
    }
}
