import Foundation

/// Named, versioned capture protocols, stored on device.
///
/// This is what "protocol as code" means in #8, and it is the README's whole
/// justification for this app over a manual camera: *the protocol lives in code
/// rather than the photographer's head, and an unnamed per-session setting is
/// the photographer's head with extra steps.*
///
/// #8's amendment allows authoring **on device, mid-shoot**, because requiring
/// a protocol be written ahead of time is a speed bump on the shoot-look-tweak
/// loop that an instrument for designing capture experiments exists to serve.
/// The provenance requirement is met differently: the version **auto-bumps** on
/// every edit, and the full definition is **inlined into the session** rather
/// than referenced by id, so a reader holding only the session knows exactly
/// what produced it with no registry to consult.
enum ProtocolLibrary {

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("protocols", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    static func all() -> [CaptureSet] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(CaptureSet.self, from: $0) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func load(named name: String) -> CaptureSet? {
        all().first { $0.name == name }
    }

    /// Saves under `name`, bumping the version past whatever is already stored.
    ///
    /// The bump is unconditional rather than change-detecting: a version that
    /// only moves when the app decides something differs is a version a reader
    /// has to trust the app about. Monotonic is worth more than tight.
    @discardableResult
    static func save(_ set: CaptureSet, as name: String) throws -> CaptureSet {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nextVersion = (load(named: name)?.version ?? 0) + 1
        let stored = CaptureSet(
            name: name, version: nextVersion, specs: set.specs,
            generator: set.generator, perSensorEVOffsetStops: set.perSensorEVOffsetStops)
        let safe = name.replacingOccurrences(of: "/", with: "_")
        try encoder.encode(stored).write(to: directory.appendingPathComponent("\(safe).json"))
        return stored
    }

    static func delete(named name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(safe).json"))
    }

    /// Examples, not constraints (#8). Offered so the common shapes are one tap;
    /// nothing stops a set being authored from scratch, and nothing about these
    /// is privileged once saved.
    static func presets() -> [(String, CaptureSet)] {
        let base = CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100)
        return [
            ("ladder-7x1stop", .shutterSweep(base: base, stopsPerRung: 1, rungs: 7, name: "ladder-7x1stop")),
            ("ladder-5x2stop", .shutterSweep(base: base, stopsPerRung: 2, rungs: 5, name: "ladder-5x2stop")),
            ("repeat-16", .repeated(base, count: 16, name: "repeat-16")),
            ("single", .repeated(base, count: 1, name: "single")),
        ]
    }
}
