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

    /// The bars, stated in the log rather than left implicit.
    ///
    /// #15 suggested the 99.9th percentile within a small margin. Measured, the
    /// tail is the **wrong statistic**: a genuinely capped frame has a read-noise
    /// tail of its own, so a margin loose enough to admit it is also loose
    /// enough to admit an uncapped frame at a short exposure. A cap-off run at
    /// 1/250 s in a dim room passed a 2% p99.9 bar.
    ///
    /// The median is unambiguous instead. Measured over two runs at identical
    /// settings: a capped frame's p50 sits at **exactly** the pedestal on all
    /// four channels, while uncapped it sits 14-29 counts above, every time.
    /// Read noise is symmetric about the pedestal, so half the pixels land on
    /// it; any light at all moves the median off it.
    let medianMarginFraction: Double
    let tailMarginFraction: Double
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
        let p50: Int
        let p999: Int
        /// How far each sits above the pedestal, as a fraction of the usable
        /// range. The median is the discriminating one.
        let medianExcessFraction: Double
        let tailExcessFraction: Double
        let passed: Bool
    }

    /// A dark frame should sit *on* the pedestal, not merely near it.
    ///
    /// The median bar is 0.05% of the usable range — about 7 counts, against a
    /// measured separation of 14-29. Deliberately not zero: dark current
    /// accumulates with exposure time and would legitimately lift the median on
    /// a long capped exposure. **That case is unmeasured** — the capped runs so
    /// far reach only 1/60 s — so if a 1 s capped frame is refused, this bar is
    /// what needs revising, and the recorded numbers say by how much.
    ///
    /// The tail bar is kept as a secondary check at the value #15 suggested. It
    /// catches gross light that the median might survive; it does not catch a
    /// dim uncapped frame, which is why it is no longer the primary.
    static func check(_ stats: ClippingStats,
                      medianMarginFraction: Double = 0.0005,
                      tailMarginFraction: Double = 0.02) -> DarkFrameValidation? {
        guard stats.unavailableReason == nil, !stats.channels.isEmpty else { return nil }

        // Levels arrive in DNG units; the histogram is in buffer units.
        let scale = stats.bufferScaleOverDNG ?? 1
        let black = (stats.declaredBlackLevel ?? 0) * scale
        let ceiling = (stats.declaredWhiteLevel ?? 4095) * scale
        let span = Swift.max(ceiling - black, 1)

        var verdicts: [ChannelVerdict] = []
        var failures: [String] = []
        for ch in stats.channels {
            let medianExcess = (Double(ch.p50) - black) / span
            let tailExcess = (Double(ch.p999) - black) / span
            let ok = medianExcess <= medianMarginFraction && tailExcess <= tailMarginFraction
            verdicts.append(ChannelVerdict(
                colour: ch.colour, cfaPosition: ch.cfaPosition, p50: ch.p50, p999: ch.p999,
                medianExcessFraction: medianExcess, tailExcessFraction: tailExcess, passed: ok))
            if medianExcess > medianMarginFraction {
                failures.append(String(format: "%@ median sits %.3f%% above the pedestal (%d vs %.0f)",
                                       ch.colour, 100 * medianExcess, ch.p50, black))
            } else if tailExcess > tailMarginFraction {
                failures.append(String(format: "%@ p99.9 sits %.2f%% above the pedestal",
                                       ch.colour, 100 * tailExcess))
            }
        }
        return DarkFrameValidation(
            medianMarginFraction: medianMarginFraction,
            tailMarginFraction: tailMarginFraction,
            blackLevelBufferUnits: black,
            ceilingBufferUnits: ceiling,
            channels: verdicts,
            passed: failures.isEmpty,
            failureReason: failures.isEmpty ? nil
                : "not dark — " + failures.joined(separator: ", ")
                + String(format: " (median bar %.3f%%)", 100 * medianMarginFraction))
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
