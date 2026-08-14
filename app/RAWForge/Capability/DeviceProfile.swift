import Foundation

/// One number the plan depends on, and where it came from.
///
/// The distinction this type exists to keep is between a figure measured on the
/// device in hand and one inherited from the phone this app was written
/// against. Both are numbers; only one is evidence. Collapsing them is what let
/// the app present an iPhone 15 Pro's timings as though they were anyone's.
struct Reading: Codable, Equatable {
    let value: Double
    let source: Source
    /// How many observations the value was drawn from. Nil when borrowed.
    let sampleCount: Int?
    /// Spread across those observations — max minus min, in the value's own
    /// units. A wide spread is not an error, but it is a reason to trust the
    /// figure less, and hiding it would be the same sin as hiding provenance.
    let spread: Double?
    /// The device the figure came from, when it did not come from this one.
    let referenceDevice: String?

    enum Source: String, Codable { case measured, borrowed }

    var isMeasured: Bool { source == .measured }

    static func measured(_ value: Double, samples: Int, spread: Double) -> Reading {
        Reading(value: value, source: .measured, sampleCount: samples,
                spread: spread, referenceDevice: nil)
    }

    static func borrowed(_ value: Double, from device: String) -> Reading {
        Reading(value: value, source: .borrowed, sampleCount: nil,
                spread: nil, referenceDevice: device)
    }
}

/// What this particular phone does, as measured rather than assumed.
///
/// Every timing and size the plan is built from used to be a `static let` taken
/// from one iPhone 15 Pro. On other hardware those are wrong, and wrong quietly:
/// the plan still renders, still reads as authoritative, and is what the
/// operator trusts when deciding whether to hold a pose. This type is the
/// answer — the figures live here, each carrying whether it was measured.
///
/// A profile is **inlined into every session header** rather than referenced,
/// on the same rule as capture protocols: a reader holding only the session
/// should be able to tell what the app believed about the hardware when it
/// planned the shoot.
struct DeviceProfile: Codable, Equatable {

    /// The device this profile describes. A profile is only applied when this
    /// matches — a restored backup must not silently apply one phone's timings
    /// to another, which is the exact failure the type exists to prevent.
    let modelIdentifier: String
    let systemVersion: String
    let appVersion: String
    /// Nil for the reference profile, which was never measured here.
    let measuredAt: Date?

    let sensorFramePeriod: Reading
    let sequentialOverheadPerFrame: Reading
    let sensorSwap: Reading
    let bracketSeam: Reading
    let averageFrameBytes: Reading
    /// The only field that changes outside a characterisation run — see
    /// `noteObservedFrame(bytes:)`.
    var worstCaseFrameBytes: Reading
    let stillnessTimeout: Reading

    // MARK: - The reference

    /// Where every figure in this app came from before there was a way to
    /// measure one: an iPhone 15 Pro, running iOS 26, over the course of
    /// building it. Honest there, borrowed everywhere else.
    static let referenceDevice = "iPhone16,1"

    static var reference: DeviceProfile {
        DeviceProfile(
            modelIdentifier: referenceDevice,
            systemVersion: "26.x",
            appVersion: "reference",
            measuredAt: nil,
            sensorFramePeriod: .borrowed(0.0334, from: referenceDevice),
            sequentialOverheadPerFrame: .borrowed(0.233, from: referenceDevice),
            sensorSwap: .borrowed(0.40, from: referenceDevice),
            bracketSeam: .borrowed(0.567, from: referenceDevice),
            averageFrameBytes: .borrowed(10_000_000, from: referenceDevice),
            worstCaseFrameBytes: .borrowed(30_700_000, from: referenceDevice),
            stillnessTimeout: .borrowed(0.4, from: referenceDevice))
    }

    // MARK: - Honesty

    var readings: [(name: String, reading: Reading)] {
        [("Frame period", sensorFramePeriod),
         ("Sequential overhead", sequentialOverheadPerFrame),
         ("Sensor swap", sensorSwap),
         ("Bracket seam", bracketSeam),
         ("Average frame size", averageFrameBytes),
         ("Largest frame seen", worstCaseFrameBytes),
         ("Stillness settle", stillnessTimeout)]
    }

    var borrowedCount: Int { readings.filter { !$0.reading.isMeasured }.count }

    /// True when the timings that a characterisation run can establish have
    /// been established here. Deliberately **not** "every reading is measured":
    /// the stillness settle is not a property of the phone (see below), so a
    /// definition requiring it could never be satisfied.
    var isCharacterised: Bool {
        measuredAt != nil && sensorFramePeriod.isMeasured && sensorSwap.isMeasured
    }

    /// Why one figure is permanently borrowed.
    ///
    /// The stillness settle is the measured decay time of the transient a
    /// finger-lift puts into the device — a property of a hand and a mount, not
    /// of the hardware. There is nothing a capture run could do to observe it:
    /// it would need somebody to tap the phone and then hold still, on cue.
    ///
    /// It is left at the value measured by replaying six real motion streams,
    /// and marked borrowed so the interface says so rather than implying this
    /// device was asked.
    static let stillnessIsNotMeasurable =
        "A settle time is how long a finger-lift takes to decay — a property of "
        + "the hand and the mount, not of the phone. No capture run can observe it."

    // MARK: - Storage

    /// App state rather than the user's data: measurements the app keeps about
    /// itself, which nobody browsing Files should be editing.
    static var fileURL: URL { AppStorage.supportFile("device-profile.json") }

    /// The profile in force. Loaded once and cached, because it is read on
    /// every estimate and the plan re-renders as the shot list is edited.
    private static var cached: DeviceProfile?

    static var active: DeviceProfile {
        if let cached { return cached }
        let loaded = loadFromDisk() ?? reference
        cached = loaded
        return loaded
    }

    /// Applies only when the stored profile describes *this* device. A profile
    /// restored from another phone's backup is discarded rather than trusted.
    private static func loadFromDisk() -> DeviceProfile? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder.rawforge.decode(DeviceProfile.self, from: data)
        else { return nil }
        let here = DeviceIdentity.current().modelIdentifier
        guard stored.modelIdentifier == here else {
            logWarn(.app, "a stored device profile describes \(stored.modelIdentifier) but this "
                    + "is \(here) — discarded rather than applied")
            return nil
        }
        return stored
    }

    @discardableResult
    func save() throws -> URL {
        let url = Self.fileURL
        try JSONEncoder.rawforge.encode(self).write(to: url, options: .atomic)
        Self.cached = self
        logInfo(.app, "device profile saved — \(readings.count - borrowedCount) of "
                + "\(readings.count) readings measured on \(modelIdentifier)")
        return url
    }

    static func forget() {
        try? FileManager.default.removeItem(at: fileURL)
        cached = nil
    }

    /// Raises the largest-frame figure when a real capture exceeds it.
    ///
    /// Frame size is the one figure a characterisation run cannot settle, because
    /// a DNG's size depends on what the lens is pointed at — a dark or flat scene
    /// compresses far smaller than a detailed one. A run measures whatever
    /// happened to be in frame, which is a floor rather than a worst case.
    ///
    /// So the worst case is learned from actual work instead: every frame the
    /// app writes is offered here, and the figure only ever goes up. That is
    /// slow, but it converges on this device's real ceiling rather than on the
    /// reference phone's.
    static func noteObservedFrame(bytes: Int) {
        let observed = Double(bytes)
        guard observed > active.worstCaseFrameBytes.value else { return }
        var updated = active
        updated.worstCaseFrameBytes = .measured(
            observed,
            samples: (active.worstCaseFrameBytes.sampleCount ?? 0) + 1,
            spread: 0)
        try? updated.save()
        logInfo(.app, "largest frame seen on this device is now "
                + "\(Int(observed / 1_000_000)) MB")
    }
}

// MARK: - Coding helpers

extension JSONEncoder {
    static var rawforge: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var rawforge: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
