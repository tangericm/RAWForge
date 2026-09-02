import Foundation

/// The launch storage transaction, kept explicit so migration always finishes
/// before orphan ownership is evaluated.
enum LaunchStorageMaintenance {
    typealias Migration = (_ sessionsRoot: URL, _ logsRoot: URL, _ markerURL: URL)
        -> RecordPrivacyMigrator.Report

    struct Report {
        let migration: RecordPrivacyMigrator.Report
        let orphanedFramesRemoved: Int
    }

    static func run(
        sessionsRoot: URL,
        logsRoot: URL,
        markerURL: URL,
        migrate: Migration = { sessionsRoot, logsRoot, markerURL in
            RecordPrivacyMigrator.migrate(
                sessionsRoot: sessionsRoot,
                logsRoot: logsRoot,
                markerURL: markerURL)
        }
    ) -> Report {
        var migration = migrate(sessionsRoot, logsRoot, markerURL)
        let orphanedFramesRemoved = migration.failures.isEmpty
            ? SessionStore.sweepOrphanedFrames(sessionsRoot: sessionsRoot)
            : 0
        if orphanedFramesRemoved > 0 {
            do {
                try RecordPrivacyMigrator.recordPendingOrphanedFramesRemoved(
                    orphanedFramesRemoved,
                    markerURL: markerURL)
            } catch {
                migration.failures.append("launch notice marker: \(error)")
            }
        }
        return Report(
            migration: migration,
            orphanedFramesRemoved: orphanedFramesRemoved)
    }
}
