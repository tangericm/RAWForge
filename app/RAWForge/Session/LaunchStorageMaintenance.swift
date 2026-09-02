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
        cleanupOperations: RecordPrivacyMigrator.OrphanCleanupOperations = .live,
        migrate: Migration = { sessionsRoot, logsRoot, markerURL in
            RecordPrivacyMigrator.migrate(
                sessionsRoot: sessionsRoot,
                logsRoot: logsRoot,
                markerURL: markerURL)
        }
    ) -> Report {
        var migration = migrate(sessionsRoot, logsRoot, markerURL)
        let disclosure = RecordPrivacyMigrator.reconcileOrphanCleanup(
            sessionsRoot: sessionsRoot,
            markerURL: markerURL,
            allowRemoval: migration.failures.isEmpty,
            operations: cleanupOperations)
        if let failure = disclosure.failure {
            migration.failures.append(failure)
        }
        return Report(
            migration: migration,
            orphanedFramesRemoved: disclosure.removed,
            orphanedFramesToDisclose: disclosure.count)
    }
}
