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

    let sessionId: String
    let openedAt: Date

    /// `systemUptime` at session open. Wall-clock is subject to NTP steps and
    /// timezone changes; inter-frame gaps (#9) are measured against a
    /// monotonic clock and anchored here.
    let openedAtUptime: TimeInterval

    let capability: CapabilityReport

    /// Named at open so the reason a sensor is missing from the frames is in
    /// the file rather than inferred (#6).
    let excluded: [Exclusion]

    struct Exclusion: Codable, Equatable {
        let sensor: String
        let reason: String
    }

    static let currentFormat = "rawforge.session"
    static let currentSchemaVersion = 1

    init(sessionId: String, openedAt: Date, openedAtUptime: TimeInterval, capability: CapabilityReport) {
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
