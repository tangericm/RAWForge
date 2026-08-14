import Foundation

/// Where the app's own state lives, as distinct from the user's data.
///
/// `UIFileSharingEnabled` exposes the **whole** of `Documents` to the Files app,
/// which is exactly what this app wants for sessions, logs and protocols —
/// those are the user's, and #11 makes Files the transfer route. It is not what
/// it wants for the shot list or the device profile: those are the app's own
/// bookkeeping, and putting them where they can be browsed, edited and deleted
/// offers a footgun for no benefit. Apple's guidance is explicit that files not
/// intended for user access belong elsewhere.
///
/// So the rule is a question about ownership, not about format: **would a
/// photographer recognise this file as something they made?** Sessions yes,
/// protocols yes, logs yes — they asked for those and may want to hand them
/// over. A cursor into a half-walked shot list, no.
enum AppStorage {

    /// `Library/Application Support/`, created on first use.
    ///
    /// Backed up by iCloud and not purgeable, which is right for both files
    /// here — losing a device profile means re-measuring, and losing a shot
    /// list mid-shoot means re-authoring it at the pose.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func supportFile(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }

    /// The user's data, and only that. Shared to Files wholesale.
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Moves a file out of `Documents` on first launch after the split.
    ///
    /// An install that predates this change already has these files in the old
    /// place, and silently starting fresh would lose a device profile that cost
    /// twenty seconds of measurement and a shot list somebody authored. The
    /// move is one-way and idempotent: once the new file exists it wins, and a
    /// stray old copy is removed rather than left to confuse the next reader.
    @discardableResult
    static func migrateFromDocuments(_ name: String) -> Bool {
        let old = documentsDirectory.appendingPathComponent(name)
        let new = supportFile(name)
        let fm = FileManager.default

        guard fm.fileExists(atPath: old.path) else { return false }
        if fm.fileExists(atPath: new.path) {
            // Both exist: the new location is authoritative, so the old copy is
            // a leftover rather than a second opinion.
            try? fm.removeItem(at: old)
            logInfo(.store, "removed a stale \(name) left in Documents")
            return false
        }
        do {
            try fm.moveItem(at: old, to: new)
            logInfo(.store, "moved \(name) out of Documents into Application Support")
            return true
        } catch {
            logFailure(.store, "moving \(name) out of Documents", error)
            return false
        }
    }

    /// Everything that has to move, in one place so the migration and the tests
    /// cannot drift apart.
    static let filesMovedOutOfDocuments = ["shot-list.json", "device-profile.json"]

    static func migrateAll() {
        for name in filesMovedOutOfDocuments { migrateFromDocuments(name) }
    }
}
