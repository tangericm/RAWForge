import Foundation

/// The session header: written once, at session open, before any frame exists.
///
/// #6 makes this the substitute for capability gating — because nothing is
/// gated, the record has to carry what a gate would have enforced. A reader
/// holding only the session directory can tell which sensors were available,
/// which were excluded and why, and therefore whether a session shot on one
/// sensor was a choice or a shortfall.
struct SessionRecord: Codable, Equatable {

    /// Named so a reader can identify the file without relying on its path,
    /// and versioned so a later schema change is detected rather than silently
    /// mis-parsed (#9).
    let format: String
    let schemaVersion: Int

    /// `scene` or `calibration`. A calibration is its own session type with its
    /// own id (#15), not a prelude to a scene session — which is what makes a
    /// stale calibration visible instead of assumed, and lets an archived scene
    /// be re-processed against a better calibration measured later.
    let sessionType: String

    /// For a scene session: which calibration it was shot under, and how old
    /// that calibration was at the time. Both recorded rather than one, because
    /// the age is the thing a reader actually needs to judge.
    let calibrationSessionId: String?
    let calibrationAgeSeconds: Double?

    /// `ProcessInfo.thermalState` at open. Four coarse buckets is all iOS
    /// exposes — there is no public sensor-temperature API — so temperature is
    /// **noted, never measured** (#15). Stating the limitation beats implying a
    /// precision that does not exist.
    let thermalStateAtOpen: String

    let sessionId: String
    let openedAt: Date

    /// `systemUptime` at session open. Wall-clock is subject to NTP steps and
    /// timezone changes; inter-frame gaps (#9) are measured against a
    /// monotonic clock and anchored here.
    let openedAtUptime: TimeInterval

    let capability: CapabilityReport

    /// Recorded at session open (#11), against the conservative capacity figure
    /// rather than the one that counts purgeable space. A session that ran out
    /// of room should be diagnosable from the log rather than from the absence
    /// of frames.
    let availableCapacityBytesAtOpen: Int64?
    let capacityMeasuredWith: String

    /// Named at open so the reason a sensor is missing from the frames is in
    /// the file rather than inferred (#6).
    let excluded: [Exclusion]

    struct Exclusion: Codable, Equatable {
        let sensor: String
        let reason: String
    }

    static let currentFormat = "rawforge.session"
    static let currentSchemaVersion = 3

    static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    init(sessionId: String, openedAt: Date, openedAtUptime: TimeInterval,
         capability: CapabilityReport, availableCapacityBytes: Int64?,
         sessionType: String = "scene",
         calibrationSessionId: String? = nil, calibrationAgeSeconds: Double? = nil) {
        self.sessionType = sessionType
        self.calibrationSessionId = calibrationSessionId
        self.calibrationAgeSeconds = calibrationAgeSeconds
        self.thermalStateAtOpen = SessionRecord.thermalLabel()
        self.availableCapacityBytesAtOpen = availableCapacityBytes
        self.capacityMeasuredWith = "URLResourceValues.volumeAvailableCapacity"
        self.format = Self.currentFormat
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionId = sessionId
        self.openedAt = openedAt
        self.openedAtUptime = openedAtUptime
        self.capability = capability
        self.excluded = capability.excludedSensors.map {
            Exclusion(sensor: $0.sensor.rawValue,
                      reason: $0.exclusionReason ?? "unusable, reason not recorded")
        }
    }
}
