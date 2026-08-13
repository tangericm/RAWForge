import Foundation

/// Validation for a dark-frame capture (#15).
///
/// This is the one place in the app that forms a verdict and refuses, and #15
/// is explicit about why the exception is justified. Everywhere else the app
/// cannot know better than the photographer, who can see the scene. Here it
/// can: a capped lens has an unambiguous signature, and there is no legitimate
/// reason to record a bright frame as a dark reference.
///
/// **A bad dark frame is worse than a missing one** — it looks like data, it is
/// wrong, and it silently corrupts every photometric claim calibrated against
/// it. So a frame that is not actually dark is not recorded as a dark frame.
/// The rejection is still written to the log as an event (#9): a log that shows
/// only successes cannot distinguish "not shot" from "shot and refused".
struct DarkFrameValidation: Codable, Equatable {

    /// The bar, stated in the log rather than left implicit. #15 suggests the
    /// 99.9th percentile within a small margin of the pedestal, per CFA
    /// channel.
    let marginFraction: Double
    let blackLevelBufferUnits: Double
    let ceilingBufferUnits: Double

    let channels: [ChannelVerdict]
    let passed: Bool
    /// Named when it fails, so the log says which channel and by how much
    /// rather than merely that something was refused.
    let failureReason: String?

    struct ChannelVerdict: Codable, Equatable {
        let colour: String
        let cfaPosition: Int
        let p999: Int
        /// How far p99.9 sits above the pedestal, as a fraction of the usable
        /// range. This is the number the bar is applied to.
        let excessAboveBlackFraction: Double
        let passed: Bool
    }

    /// A dark frame should sit on the pedestal plus read noise and nothing
    /// else. `marginFraction` defaults to 2% of the usable range — generous
    /// against read noise, which at base ISO is a few counts, and nowhere near
    /// generous enough to admit a frame with light on it.
    static func check(_ stats: ClippingStats, marginFraction: Double = 0.02) -> DarkFrameValidation? {
        guard stats.unavailableReason == nil, !stats.channels.isEmpty else { return nil }

        // Levels arrive in DNG units; the histogram is in buffer units.
        let scale = stats.bufferScaleOverDNG ?? 1
        let black = (stats.declaredBlackLevel ?? 0) * scale
        let ceiling = (stats.declaredWhiteLevel ?? 4095) * scale
        let span = Swift.max(ceiling - black, 1)

        var verdicts: [ChannelVerdict] = []
        var failures: [String] = []
        for ch in stats.channels {
            let excess = (Double(ch.p999) - black) / span
            let ok = excess <= marginFraction
            verdicts.append(ChannelVerdict(
                colour: ch.colour, cfaPosition: ch.cfaPosition, p999: ch.p999,
                excessAboveBlackFraction: excess, passed: ok))
            if !ok {
                failures.append(String(format: "%@ p99.9 sits %.1f%% above the pedestal",
                                       ch.colour, 100 * excess))
            }
        }
        return DarkFrameValidation(
            marginFraction: marginFraction,
            blackLevelBufferUnits: black,
            ceilingBufferUnits: ceiling,
            channels: verdicts,
            passed: failures.isEmpty,
            failureReason: failures.isEmpty ? nil
                : "not dark — " + failures.joined(separator: ", ")
                + String(format: " (bar is %.1f%%)", 100 * marginFraction))
    }
}

/// A frame that was captured and refused. Written to the log so the record
/// distinguishes "not shot" from "shot and rejected" (#9).
struct DarkFrameRejection: Codable, Equatable {
    let sensor: String
    let shutterSeconds: Double
    let iso: Float
    let repeatIndex: Int
    let validation: DarkFrameValidation?
    let note: String
}

/// One `(shutter, ISO)` setting's worth of dark frames.
///
/// The abort unit for a calibration run is **this**, not the whole run (#15's
/// amendment). Everywhere else abort is cheap because the pose is the expensive
/// thing and a station is small — but a dark shoot has no stations and no
/// poses, it is a lens cap on a desk, and the full mirror is 336 frames and
/// ~3.4 GB. Discarding that at frame 300 would be a real loss with nothing to
/// justify it, since none of it depends on a pose that has since moved.
struct DarkSettingRecord: Codable, Equatable {
    let sensor: String
    let shutterSeconds: Double
    let iso: Float
    let requestedRepeats: Int
    let frames: [FrameRecord]
    let rejections: [DarkFrameRejection]
    /// True when this setting was abandoned partway. The rest of the run
    /// continues regardless.
    let aborted: Bool
    let abortReason: String?
}
