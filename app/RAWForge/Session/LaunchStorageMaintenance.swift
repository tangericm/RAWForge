import Foundation

/// The launch storage transaction, kept explicit so migration always finishes
/// before orphan ownership is evaluated.
enum LaunchStorageMaintenance {
    typealias Migration = (_ sessionsRoot: URL, _ logsRoot: URL, _ markerURL: URL)
        -> RecordPrivacyMigrator.Report

    struct Report {
        let migration: RecordPrivacyMigrator.Report
        let orphanedFramesRemoved: Int
        let orphanedFramesToDisclose: Int
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
        var orphanedFramesToDisclose = 0
        if migration.failures.isEmpty {
            let disclosure = RecordPrivacyMigrator.pendingOrphanRemovalDisclosure(
                orphanedFramesRemoved,
                markerURL: markerURL)
            orphanedFramesToDisclose = disclosure.count
            if let failure = disclosure.persistenceFailure {
                migration.failures.append("launch notice marker: \(failure)")
            }
        }
        return Report(
            migration: migration,
            orphanedFramesRemoved: orphanedFramesRemoved,
            orphanedFramesToDisclose: orphanedFramesToDisclose)
    }
}
