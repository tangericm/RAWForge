import Foundation

/// What was asked for, what the device says it did, and what the file says —
/// the three witnesses (#9). A disagreement between them is a finding, so all
/// three are recorded rather than reconciled at capture time.
struct FrameRecord: Codable, Equatable {

    let frameIndex: Int
    let filename: String
    let sensor: String

    /// The protocol's demand. Authored, never scene-derived (#8).
    let requested: Exposure

    /// What `AVCaptureDevice` reported after the lock settled. Absent in a
    /// hardware bracket, where the device is not reconfigured per frame and
    /// reading it back would describe the last rung for every frame.
    let deviceAchieved: Exposure?

    /// What the `AVCapturePhoto`'s own EXIF says. Measured to differ from the
    /// device read-back — consistently by 0.11% on a repeat run, and by up to
    /// 0.9% across a sweep — so the two are separate claims, not one.
    let photoAchieved: Exposure?

    /// What the written DNG says. Read back from the file the app just wrote,
    /// so a writer that silently rounds or drops a value is caught.
    let dng: DNGWitness

    /// `videoZoomFactor` at the moment of capture. Always 1.0 by construction —
    /// recorded because it is a precondition of the payload being genuine
    /// full-sensor Bayer, and a claim the file cannot otherwise substantiate.
    let zoomFactor: Double?

    /// `systemUptime` at capture. Monotonic, so inter-frame gaps survive an NTP
    /// step or a timezone change mid-session (#9).
    let capturedAtUptime: TimeInterval
    let capturedAt: Date

    /// `AVCapturePhoto.timestamp`, the capture pipeline's own clock. More
    /// precise than anything measurable around the call, and the right source
    /// for inter-frame gaps (#14 item 9).
    let photoTimestampSeconds: Double?

    /// Gap from the previous frame in the same bracket, taken from
    /// `photoTimestampSeconds` where available. Nil for the first frame.
    let gapFromPreviousSeconds: TimeInterval?

    /// Per-CFA-channel distribution of the real Bayer payload over the
    /// `ActiveArea` crop (#8). A recorded number, never a verdict — the
    /// workstation decides what counts as clipped, and can revise that decision
    /// against frames already shot because the histogram is kept.
    let clipping: ClippingStats?

    /// How still the device was held across this frame's exposure. Recorded,
    /// never judged — motion is an observable and never a pose (#10), and the
    /// threshold that will eventually gate a station abort comes from these
    /// numbers rather than preceding them.
    let motion: MotionSummary?

    /// The same statistics over a wider window centred on the frame.
    ///
    /// The exposure window is the physically correct one for motion blur, but a
    /// 1/250 s exposure is shorter than the sampling interval, so `motion`
    /// above can hold a single sample. This is deliberately a *neighbourhood*
    /// statistic — it describes how still the device was around the frame, not
    /// during it — and both windows carry their own bounds so the two are never
    /// mistaken for each other.
    let motionNeighbourhood: MotionSummary?

    /// `systemUptime` read immediately after the photo arrived, paired with the
    /// pipeline's own `photoTimestampSeconds` and the motion stream's clock so
    /// the offset between the three is visible rather than assumed (#14 item 20).
    let uptimeAtDelivery: TimeInterval?
    let latestMotionTimestamp: TimeInterval?

    struct Exposure: Codable, Equatable {
        let shutterSeconds: Double
        let iso: Float
        /// Set and read-back gains both kept: the system normalises so the
        /// minimum channel is 1.0 (`R:2 G:2 B:4` → `R:1 G:1 B:2`), so what is
        /// set is not what reads back. Ratios survive, absolute scale does not.
        let whiteBalanceGains: [Float]?
    }

    struct DNGWitness: Codable, Equatable {
        let exposureTimeSeconds: Double?
        let iso: Int?
        let asShotNeutral: [Double]?
        let blackLevel: [Double]?
        let whiteLevel: [Double]?
        let cfaPattern: String?
        let activeArea: [Int]?
        let uniqueCameraModel: String?
        let localizedCameraModel: String?
        /// As ImageIO reports it — kept only to show what a coercing reader
        /// sees. **Not authoritative**: ImageIO renders both `0/0` and `0/1` as
        /// `0`, and those are opposite claims.
        let noiseReductionAppliedCoerced: String?

        /// The unreduced rational, read straight from the IFD. `0/0` means
        /// *unknown* per the DNG spec, not zero — this is the field to believe.
        let noiseReductionApplied: DNGRawTags.Rational?

        let noiseProfile: [Double]?
        let dateTimeOriginal: String?
        let subsecTimeOriginal: String?

        /// The width actually stored in the file, padding columns included.
        /// Larger than the active area — on this sensor 4224 against an
        /// `ActiveArea` of 4032, so 192 columns must be cropped downstream.
        let storedImageWidth: Int?

        /// What ImageIO reports, which is the *cropped* size — kept because the
        /// difference from `storedImageWidth` is exactly the padding.
        let imageWidth: Int?
        let imageHeight: Int?
    }
}

/// One bracket: an ordered run of frames from a single sensor at one station.
/// The sensor is an attribute of the bracket, not of the station (#7).
struct BracketRecord: Codable, Equatable {
    let bracketIndex: Int
    let sensor: String
    let sensorUniqueID: String?

    /// The full definition, inlined rather than referenced by id (#8) — a
    /// reader holding only this session knows exactly what protocol produced
    /// it, with no external registry to consult.
    let captureSet: CaptureSet?

    /// What actually fired on this sensor after its EV offset was applied.
    /// The canonical definition is in `captureSet`; this is the rendering (#8).
    let renderedSpecs: [CaptureSpec]?
    let evOffsetStops: Double?

    /// How it ran. The choice is about inter-frame gap, not about what can be
    /// expressed, so it is recorded alongside the timings it explains.
    let executionMode: String?

    /// How a bracketed set was split across hardware requests — `[8, 8]` for
    /// sixteen frames on a sensor with a ceiling of eight.
    ///
    /// Recorded because the seams are real: frames inside one request are
    /// pipeline-bound and evenly spaced, and the gap across a seam is longer.
    /// A reader comparing inter-frame timings would otherwise see an
    /// unexplained outlier every eighth frame and have to guess at it. Nil for
    /// sequential runs, and for sessions written before splitting existed.
    let bracketRequestSizes: [Int]?

    /// Rungs the sensor's rails refused. Recorded, never clamped (#8): a log
    /// that shows only what was shot cannot distinguish "not asked for" from
    /// "asked for and impossible".
    let droppedRungs: [DroppedRung]

    /// The floor on frame spacing this run was executed under, if any.
    let minimumInterFrameGapSeconds: Double?

    /// Whether the stillness wait reached the tripod band before firing, and
    /// how long it took.
    ///
    /// Recorded because the wait has no override: if it routinely times out,
    /// every set in that session carries up to four seconds of dead time and
    /// the frames were shot at whatever motion the device happened to be at.
    /// A reader should be able to tell a set that fired still from one that
    /// fired because the clock ran out.
    let stillnessSettled: Bool?
    let stillnessWaitSeconds: Double?
    /// Motion over the last moment before the first frame fired.
    let motionAtFire: MotionSummary?

    /// A wait after the sensor is configured and before the first frame fires
    /// (#8's optional dwell, distinct from the inter-frame gap).
    ///
    /// Motivated by measurement: the single largest motion event across two
    /// instrumented stations fell in the window immediately after the button
    /// tap — gyro 0.44 rad/s against a station median of 0.023 — which is
    /// finger-lift, not anything about capture. A dwell lets that decay before
    /// the first frame instead of putting it inside one.
    let dwellSeconds: Double?

    /// What this bracket was for, when it is one arm of a deliberate
    /// comparison — the warm and cool halves of the white-balance probe are
    /// otherwise distinguishable only by reading their gains.
    let note: String?

    let frames: [FrameRecord]
}

/// A station is a pose, full stop — and may span sensors (#7). It either
/// completed or never existed (#10), so there is no partial-completion state
/// and no amendment mechanism to represent here.
struct StationRecord: Codable, Equatable {
    let format: String
    let schemaVersion: Int

    let stationIndex: Int
    let sessionId: String
    let openedAt: Date
    let closedAt: Date
    let brackets: [BracketRecord]

    /// What the operator declared this station to be — mounting condition,
    /// scene, whatever makes it identifiable later.
    ///
    /// #9's record set names "pose intent" as a per-station field, and item 21
    /// needs it: three stillness conditions that differ only in how the phone
    /// was held are indistinguishable in the log without it.
    let poseIntent: String?

    /// What the pre-flight estimate predicted, against `openedAt`/`closedAt`.
    /// Kept so the estimate is checkable rather than merely reassuring — its
    /// constants were measured on a cool device, and thermal throttling moves
    /// them without announcing itself.
    let estimatedSeconds: Double?

    /// Every sensor change made within this station, and what it cost.
    ///
    /// #7 left the reconfiguration cost unmeasured and named it the one
    /// measurement that could force a stillness observation across the swap
    /// from optional to mandatory. Recording it on every real station is
    /// strictly better than measuring it once.
    let sensorSwaps: [SwapRecord]

    /// The whole station's motion, and the raw stream's filename. The summary
    /// is here so the log is self-sufficient; the samples live beside it
    /// because a per-frame motion axis is the point (#9).
    let motion: MotionSummary?
    let motionStreamFile: String?

    /// What the sampler asked for. Compare against the summary's `effectiveHz`
    /// to see what the device actually delivered.
    let motionRequestedHz: Double?

    struct SwapRecord: Codable, Equatable {
        let fromSensor: String?
        let toSensor: String
        /// Wall-clock cost of reconfiguring the session's input, in seconds.
        /// This is the window during which the pose is unheld and nothing is
        /// being captured.
        let durationSeconds: Double

        /// Measured at ~400 ms, a swap is longer than an entire 8-frame
        /// bracket, so what the device does during it is observed rather than
        /// assumed (#7).
        let motion: MotionSummary?
    }

    static let currentFormat = "rawforge.station"
    static let currentSchemaVersion = 2

    init(stationIndex: Int, sessionId: String, openedAt: Date, closedAt: Date,
         brackets: [BracketRecord], sensorSwaps: [SwapRecord] = [],
         motion: MotionSummary? = nil, motionStreamFile: String? = nil,
         motionRequestedHz: Double? = nil, poseIntent: String? = nil,
         estimatedSeconds: Double? = nil) {
        self.estimatedSeconds = estimatedSeconds
        self.poseIntent = poseIntent?.isEmpty == true ? nil : poseIntent
        self.sensorSwaps = sensorSwaps
        self.motion = motion
        self.motionStreamFile = motionStreamFile
        self.motionRequestedHz = motionRequestedHz
        self.format = Self.currentFormat
        self.schemaVersion = Self.currentSchemaVersion
        self.stationIndex = stationIndex
        self.sessionId = sessionId
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.brackets = brackets
    }
}
