import Combine
import CryptoKit
import Foundation

/// Upgrades the one shipped metadata generation that persisted raw system uptime.
///
/// A session directory is the transaction boundary. Every recognized replacement is
/// decoded, staged, read back, and decoded as its current type before the first source
/// is exchanged. Sibling backups make a later exchange or validation failure reversible.
enum RecordPrivacyMigrator {
    static let migrationVersion = 1

    typealias Exchange = (_ source: URL, _ replacement: URL) throws -> Void

    struct FileOperations {
        var exchange: Exchange
        var copyItem: (_ source: URL, _ destination: URL) throws -> Void
        var moveItem: (_ source: URL, _ destination: URL) throws -> Void
        var removeItem: (_ url: URL) throws -> Void
        var writeAtomically: (_ data: Data, _ url: URL) throws -> Void
        var isDirectory: (_ url: URL) throws -> Bool

        static var live: FileOperations {
            FileOperations(
                exchange: RecordPrivacyMigrator.atomicExchange,
                copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
                moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
                removeItem: { try FileManager.default.removeItem(at: $0) },
                writeAtomically: { try $0.write(to: $1, options: .atomic) },
                isDirectory: {
                    try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                })
        }
    }

    struct Report: Equatable {
        var migratedSessions = 0
        var removedLogs = 0
        var untouchedUnknownRecords = 0
        var failures: [String] = []
    }

    static func migrate(
        sessionsRoot: URL,
        logsRoot: URL,
        markerURL: URL,
        exchange: Exchange? = nil,
        operations: FileOperations = .live
    ) -> Report {
        var operations = operations
        if let exchange { operations.exchange = exchange }
        var report = Report()
        let marker: PrivacyMigrationMarker
        do {
            marker = try PrivacyMigrationMarkerStore.load(from: markerURL)
        } catch {
            report.failures.append("privacy migration marker: \(error)")
            return report
        }
        var updatedMarker = marker

        let directories: [URL]
        do {
            directories = try sessionDirectories(at: sessionsRoot, operations: operations)
        } catch {
            directories = []
            report.failures.append("sessions discovery: \(error)")
        }
        for directory in directories {
            var sessionUnknownRecords = 0
            do {
                if try migrateSession(
                    in: directory,
                    unknownRecords: &sessionUnknownRecords,
                    operations: operations
                ) {
                    report.migratedSessions += 1
                }
            } catch {
                report.failures.append("\(directory.lastPathComponent): \(error)")
            }
            report.untouchedUnknownRecords += sessionUnknownRecords
        }

        var quarantinedLogs: LogCleanupPlan?
        if updatedMarker.logsClearedMigrationVersion != migrationVersion {
            do {
                let cleanup = try quarantineLegacyLogs(at: logsRoot, operations: operations)
                quarantinedLogs = cleanup
                updatedMarker.logsClearedMigrationVersion = migrationVersion
                if (cleanup?.entryCount ?? 0) > 0, updatedMarker.noticeState == .none {
                    updatedMarker.noticeState = .pending
                }
            } catch {
                report.failures.append("legacy logs quarantine: \(error)")
            }
        } else {
            do {
                report.removedLogs = try finishCommittedLogCleanup(
                    at: logsRoot, operations: operations)
            } catch {
                report.failures.append("legacy logs cleanup: \(error)")
            }
        }

        if report.failures.isEmpty, report.untouchedUnknownRecords == 0 {
            updatedMarker.completedMigrationVersion = migrationVersion
        } else {
            updatedMarker.completedMigrationVersion = nil
        }

        do {
            try PrivacyMigrationMarkerStore.save(
                updatedMarker,
                to: markerURL,
                writeAtomically: operations.writeAtomically)
        } catch {
            report.failures.append("privacy migration marker: \(error)")
            return report
        }
        if let quarantinedLogs {
            do {
                try operations.removeItem(quarantinedLogs.quarantineURL)
                report.removedLogs = quarantinedLogs.entryCount
            } catch {
                report.failures.append("legacy logs cleanup: \(error)")
            }
        }
        return report
    }

    private enum MetadataKind: String, Codable, Equatable {
        case session
        case station
        case darkSetting
        case motionStream
    }

    private struct Replacement {
        let source: URL
        let data: Data
        let kind: MetadataKind

        var staged: URL { source.appendingPathExtension("privacy-migration") }
        var backup: URL { source.appendingPathExtension("privacy-backup") }
        var backupCreating: URL { source.appendingPathExtension("privacy-backup-creating") }
        var restore: URL { source.appendingPathExtension("privacy-restore") }
    }

    private struct MetadataTransactionManifest: Codable {
        enum State: String, Codable {
            case preparing
            case preCommit
            case committed
        }

        struct Entry: Codable {
            let sourceName: String
            let kind: MetadataKind
            let originalByteCount: Int
            let originalSHA256: String
            let currentByteCount: Int
            let currentSHA256: String
        }

        var format = "rawforge.privacy-metadata-transaction"
        var schemaVersion = 1
        var migrationVersion = RecordPrivacyMigrator.migrationVersion
        var state: State
        let entries: [Entry]
    }

    private static let metadataTransactionManifestName =
        ".privacy-metadata-transaction-v1.json"

    private struct LogCleanupManifest: Codable {
        struct Entry: Codable {
            let name: String
            let byteCount: Int
            let sha256: String
        }

        var format = "rawforge.privacy-log-cleanup"
        var schemaVersion = 1
        var migrationVersion = RecordPrivacyMigrator.migrationVersion
        let entries: [Entry]
    }

    private struct LogCleanupPlan {
        let quarantineURL: URL
        let entryCount: Int
    }

    private static let logQuarantineName = ".privacy-log-cleanup-v1"
    private static let logCleanupManifestName = "manifest.json"

    private static func migrateSession(
        in directory: URL,
        unknownRecords: inout Int,
        operations: FileOperations
    ) throws -> Bool {
        try recoverInterruptedTransaction(in: directory, operations: operations)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        let sessionURL = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw MigrationError.missingSessionHeader
        }

        let stationURLs = files.filter {
            $0.lastPathComponent.hasPrefix("station-") && $0.pathExtension == "json"
        }.sorted(by: pathOrder)
        let darkURLs = files.filter {
            $0.lastPathComponent.hasPrefix("dark-") && $0.pathExtension == "json"
        }.sorted(by: pathOrder)
        let motionURLs = files.filter {
            $0.lastPathComponent.hasPrefix("motion-") && $0.pathExtension == "jsonl"
        }.sorted(by: pathOrder)

        let sessionData = try Data(contentsOf: sessionURL)
        let envelope = try decoder.decode(RecordEnvelope.self, from: sessionData)
        var replacements: [Replacement] = []
        var legacyOrigin: TimeInterval?

        switch (envelope.format, envelope.schemaVersion) {
        case (SessionRecord.currentFormat, 4):
            let legacy = try decoder.decode(LegacySessionV4.self, from: sessionData)
            legacyOrigin = legacy.openedAtUptime
            replacements.append(Replacement(
                source: sessionURL,
                data: try migratedSessionData(sessionData),
                kind: .session))
        case (SessionRecord.currentFormat, SessionRecord.currentSchemaVersion):
            try validateCurrent(sessionData, as: .session)
        default:
            unknownRecords += 1
        }

        for url in stationURLs {
            let data = try Data(contentsOf: url)
            let stationEnvelope = try decoder.decode(RecordEnvelope.self, from: data)
            switch (stationEnvelope.format, stationEnvelope.schemaVersion) {
            case (StationRecord.currentFormat, 2):
                guard let origin = legacyOrigin else {
                    throw MigrationError.legacyStationWithoutAnchor(url.lastPathComponent)
                }
                _ = try decoder.decode(LegacyStationV2.self, from: data)
                replacements.append(Replacement(
                    source: url,
                    data: try migratedStationData(
                        data,
                        origin: origin,
                        segmentID: "privacy-migration-\(directory.lastPathComponent)"),
                    kind: .station))
            case (StationRecord.currentFormat, 3):
                guard let origin = legacyOrigin else {
                    throw MigrationError.legacyStationWithoutAnchor(url.lastPathComponent)
                }
                replacements.append(Replacement(
                    source: url,
                    data: try migratedStationV3Data(data, origin: origin),
                    kind: .station))
            case (StationRecord.currentFormat, StationRecord.currentSchemaVersion):
                try validateCurrent(data, as: .station)
            default:
                unknownRecords += 1
            }
        }

        if let origin = legacyOrigin {
            for url in darkURLs {
                let data = try Data(contentsOf: url)
                let containsLegacyPhotoTimestamp = try darkSettingContainsLegacyPhotoTimestamp(data)
                if (try? decoder.decode(DarkSettingRecord.self, from: data)) != nil {
                    if containsLegacyPhotoTimestamp {
                        replacements.append(Replacement(
                            source: url,
                            data: try migratedUnversionedDarkSettingData(
                                data, origin: origin),
                            kind: .darkSetting))
                    } else {
                        try validateCurrent(data, as: .darkSetting)
                    }
                } else {
                    _ = try decoder.decode(LegacyDarkSettingRecord.self, from: data)
                    replacements.append(Replacement(
                        source: url,
                        data: try migratedDarkSettingData(data, origin: origin),
                        kind: .darkSetting))
                }
            }
            for url in motionURLs {
                let data = try Data(contentsOf: url)
                if (try? decodeMotionLines(MotionSample.self, from: data)) != nil {
                    try validateCurrent(data, as: .motionStream)
                } else {
                    replacements.append(Replacement(
                        source: url,
                        data: try migratedMotionData(data, origin: origin),
                        kind: .motionStream))
                }
            }
        } else if envelope.format == SessionRecord.currentFormat,
                  envelope.schemaVersion == SessionRecord.currentSchemaVersion {
            for url in darkURLs {
                let data = try Data(contentsOf: url)
                if try darkSettingContainsLegacyPhotoTimestamp(data) {
                    throw MigrationError.legacyDarkSettingWithoutAnchor(url.lastPathComponent)
                }
                try validateCurrent(data, as: .darkSetting)
            }
            for url in motionURLs {
                try validateCurrent(Data(contentsOf: url), as: .motionStream)
            }
        }

        // An unknown child may need the legacy header's anchor in a future version.
        // Preserve the complete directory rather than stranding it behind a v5 header.
        guard unknownRecords == 0 else {
            return false
        }
        guard !replacements.isEmpty else {
            return false
        }

        try transact(
            replacements.sorted { pathOrder($0.source, $1.source) },
            operations: operations)
        return true
    }

    // MARK: - Transaction

    private static func transact(
        _ replacements: [Replacement],
        operations: FileOperations
    ) throws {
        let fm = FileManager.default
        var staged: [Replacement] = []
        do {
            for replacement in replacements {
                try removeIfPresent(replacement.staged, operations: operations)
                try operations.writeAtomically(replacement.data, replacement.staged)
                let stagedData = try Data(contentsOf: replacement.staged)
                guard stagedData == replacement.data else {
                    throw MigrationError.stagedBytesChanged(replacement.source.lastPathComponent)
                }
                try validateCurrent(stagedData, as: replacement.kind)
                staged.append(replacement)
            }
        } catch {
            for replacement in staged { try? fm.removeItem(at: replacement.staged) }
            for replacement in replacements where !staged.contains(where: {
                $0.source == replacement.source
            }) {
                try? fm.removeItem(at: replacement.staged)
            }
            throw error
        }

        let originals: [URL: Data]
        do {
            originals = try Dictionary(uniqueKeysWithValues: replacements.map {
                ($0.source, try Data(contentsOf: $0.source))
            })
        } catch {
            for replacement in replacements { try? operations.removeItem(replacement.staged) }
            throw error
        }
        let manifestURL = replacements[0].source.deletingLastPathComponent()
            .appendingPathComponent(metadataTransactionManifestName)
        let entries = replacements.map { replacement in
            let original = originals[replacement.source] ?? Data()
            return MetadataTransactionManifest.Entry(
                sourceName: replacement.source.lastPathComponent,
                kind: replacement.kind,
                originalByteCount: original.count,
                originalSHA256: sha256(original),
                currentByteCount: replacement.data.count,
                currentSHA256: sha256(replacement.data))
        }
        var manifest = MetadataTransactionManifest(state: .preparing, entries: entries)
        do {
            try saveMetadataManifest(manifest, to: manifestURL, operations: operations)
            for replacement in replacements {
                guard !fm.fileExists(atPath: replacement.backup.path),
                      !fm.fileExists(atPath: replacement.backupCreating.path) else {
                    throw MigrationError.transactionArtifactAlreadyExists(
                        replacement.source.lastPathComponent)
                }
                let original = try requiredOriginal(
                    for: replacement.source, in: originals)
                try operations.copyItem(replacement.source, replacement.backupCreating)
                guard try Data(contentsOf: replacement.backupCreating) == original else {
                    throw MigrationError.backupBytesChanged(replacement.source.lastPathComponent)
                }
                try operations.moveItem(replacement.backupCreating, replacement.backup)
                guard try Data(contentsOf: replacement.backup) == original else {
                    throw MigrationError.backupBytesChanged(replacement.source.lastPathComponent)
                }
            }
            try validateCompleteBackupSet(
                entries, in: manifestURL.deletingLastPathComponent())
            manifest.state = .preCommit
            try saveMetadataManifest(manifest, to: manifestURL, operations: operations)
        } catch {
            bestEffortCleanupBeforeCommit(
                replacements, manifestURL: manifestURL, operations: operations)
            throw error
        }

        do {
            for replacement in replacements {
                try operations.exchange(replacement.source, replacement.staged)
                let installed = try Data(contentsOf: replacement.source)
                guard installed == replacement.data else {
                    throw MigrationError.exchangedBytesChanged(
                        replacement.source.lastPathComponent)
                }
                try validateCurrent(installed, as: replacement.kind)
            }
            for replacement in replacements {
                try validateCurrent(Data(contentsOf: replacement.source), as: replacement.kind)
            }
            manifest.state = .committed
            try saveMetadataManifest(manifest, to: manifestURL, operations: operations)
        } catch {
            do {
                try restore(
                    replacements,
                    expectedBytes: originals,
                    operations: operations)
                manifest.state = .preparing
                try saveMetadataManifest(manifest, to: manifestURL, operations: operations)
                try cleanupTransactionArtifacts(
                    replacements, manifestURL: manifestURL, operations: operations)
            } catch let rollbackError {
                throw MigrationError.rollbackFailed(
                    exchangeError: String(describing: error),
                    rollbackError: String(describing: rollbackError))
            }
            throw error
        }

        do {
            try cleanupTransactionArtifacts(
                replacements, manifestURL: manifestURL, operations: operations)
        } catch {
            throw MigrationError.backupCleanupFailed(String(describing: error))
        }
    }

    private static func recoverInterruptedTransaction(
        in directory: URL,
        operations: FileOperations
    ) throws {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent(metadataTransactionManifestName)
        if fm.fileExists(atPath: manifestURL.path) {
            var manifest = try loadMetadataManifest(from: manifestURL)
            let replacements = try replacements(for: manifest.entries, in: directory)
            try validateOwnedTransactionArtifacts(manifest.entries, in: directory)
            switch manifest.state {
            case .preparing:
                for (entry, replacement) in zip(manifest.entries, replacements) {
                    try validateFingerprint(
                        Data(contentsOf: replacement.source),
                        byteCount: entry.originalByteCount,
                        sha256: entry.originalSHA256,
                        error: .sourceChangedBeforeCommit(entry.sourceName))
                }
                try cleanupTransactionArtifacts(
                    replacements, manifestURL: manifestURL, operations: operations)
            case .preCommit:
                try validateCompleteBackupSet(manifest.entries, in: directory)
                let originals = try Dictionary(uniqueKeysWithValues: zip(
                    replacements, manifest.entries).map { replacement, entry in
                        let data = try Data(contentsOf: replacement.backup)
                        try validateFingerprint(
                            data,
                            byteCount: entry.originalByteCount,
                            sha256: entry.originalSHA256,
                            error: .backupBytesChanged(entry.sourceName))
                        return (replacement.source, data)
                    })
                try restore(
                    replacements,
                    expectedBytes: originals,
                    operations: operations)
                manifest.state = .preparing
                try saveMetadataManifest(manifest, to: manifestURL, operations: operations)
                try cleanupTransactionArtifacts(
                    replacements, manifestURL: manifestURL, operations: operations)
            case .committed:
                for (entry, replacement) in zip(manifest.entries, replacements) {
                    let installed = try Data(contentsOf: replacement.source)
                    try validateFingerprint(
                        installed,
                        byteCount: entry.currentByteCount,
                        sha256: entry.currentSHA256,
                        error: .committedSourceChanged(entry.sourceName))
                    try validateCurrent(installed, as: entry.kind)
                }
                try cleanupTransactionArtifacts(
                    replacements, manifestURL: manifestURL, operations: operations)
            }
            return
        }

        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        if let backup = files.first(where: {
            $0.lastPathComponent.hasSuffix(".privacy-backup")
        }) {
            throw MigrationError.unownedBackup(backup.lastPathComponent)
        }
        for url in files where url.lastPathComponent.hasSuffix(".privacy-migration")
                || url.lastPathComponent.hasSuffix(".privacy-backup-creating")
                || url.lastPathComponent.hasSuffix(".privacy-restore") {
            try operations.removeItem(url)
        }
    }

    private static func saveMetadataManifest(
        _ manifest: MetadataTransactionManifest,
        to url: URL,
        operations: FileOperations
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try operations.writeAtomically(encoder.encode(manifest), url)
    }

    private static func loadMetadataManifest(
        from url: URL
    ) throws -> MetadataTransactionManifest {
        let manifest = try JSONDecoder().decode(
            MetadataTransactionManifest.self, from: Data(contentsOf: url))
        guard manifest.format == "rawforge.privacy-metadata-transaction",
              manifest.schemaVersion == 1,
              manifest.migrationVersion == migrationVersion,
              !manifest.entries.isEmpty else {
            throw MigrationError.invalidTransactionManifest
        }
        _ = try replacements(for: manifest.entries, in: url.deletingLastPathComponent())
        return manifest
    }

    private static func replacements(
        for entries: [MetadataTransactionManifest.Entry],
        in directory: URL
    ) throws -> [Replacement] {
        var sourceNames = Set<String>()
        var replacements: [Replacement] = []
        for entry in entries {
            guard entry.sourceName == URL(fileURLWithPath: entry.sourceName).lastPathComponent,
                  entry.sourceName != ".", entry.sourceName != "..",
                  sourceNames.insert(entry.sourceName).inserted else {
                throw MigrationError.invalidTransactionManifest
            }
            let source = directory.appendingPathComponent(entry.sourceName)
            guard try metadataKind(for: source) == entry.kind else {
                throw MigrationError.invalidTransactionManifest
            }
            replacements.append(Replacement(source: source, data: Data(), kind: entry.kind))
        }
        guard replacements.contains(where: { $0.kind == .session }) else {
            throw MigrationError.invalidTransactionManifest
        }
        return replacements
    }

    private static func validateCompleteBackupSet(
        _ entries: [MetadataTransactionManifest.Entry],
        in directory: URL
    ) throws {
        let expectedNames = Set(entries.map { "\($0.sourceName).privacy-backup" })
        let actualNames = try Set(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".privacy-backup") })
        guard actualNames == expectedNames else {
            throw MigrationError.incompleteBackupSet(
                expectedNames.subtracting(actualNames).sorted().first
                    ?? actualNames.subtracting(expectedNames).sorted().first
                    ?? "unknown")
        }
        for (entry, replacement) in zip(entries, try replacements(for: entries, in: directory)) {
            guard FileManager.default.fileExists(atPath: replacement.backup.path) else {
                throw MigrationError.incompleteBackupSet(entry.sourceName)
            }
            try validateFingerprint(
                Data(contentsOf: replacement.backup),
                byteCount: entry.originalByteCount,
                sha256: entry.originalSHA256,
                error: .backupBytesChanged(entry.sourceName))
        }
    }

    private static func validateOwnedTransactionArtifacts(
        _ entries: [MetadataTransactionManifest.Entry],
        in directory: URL
    ) throws {
        let suffixes = [
            ".privacy-migration",
            ".privacy-backup-creating",
            ".privacy-backup",
            ".privacy-restore",
        ]
        let expected = Set(entries.flatMap { entry in
            suffixes.map { entry.sourceName + $0 }
        })
        let actual = try Set(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { name in suffixes.contains(where: { name.hasSuffix($0) }) })
        guard actual.isSubset(of: expected) else {
            throw MigrationError.invalidTransactionManifest
        }
    }

    private static func validateFingerprint(
        _ data: Data,
        byteCount: Int,
        sha256 expectedSHA256: String,
        error: MigrationError
    ) throws {
        guard data.count == byteCount, sha256(data) == expectedSHA256 else { throw error }
    }

    private static func requiredOriginal(
        for source: URL,
        in originals: [URL: Data]
    ) throws -> Data {
        guard let original = originals[source] else {
            throw MigrationError.invalidTransactionManifest
        }
        return original
    }

    private static func cleanupTransactionArtifacts(
        _ replacements: [Replacement],
        manifestURL: URL,
        operations: FileOperations
    ) throws {
        for replacement in replacements {
            try removeIfPresent(replacement.staged, operations: operations)
            try removeIfPresent(replacement.backupCreating, operations: operations)
            try removeIfPresent(replacement.backup, operations: operations)
            try removeIfPresent(replacement.restore, operations: operations)
        }
        try operations.removeItem(manifestURL)
    }

    private static func bestEffortCleanupBeforeCommit(
        _ replacements: [Replacement],
        manifestURL: URL,
        operations: FileOperations
    ) {
        for replacement in replacements {
            try? operations.removeItem(replacement.staged)
            try? operations.removeItem(replacement.backupCreating)
            try? operations.removeItem(replacement.backup)
            try? operations.removeItem(replacement.restore)
        }
        let fm = FileManager.default
        let artifactsRemain = replacements.contains { replacement in
            fm.fileExists(atPath: replacement.staged.path)
                || fm.fileExists(atPath: replacement.backupCreating.path)
                || fm.fileExists(atPath: replacement.backup.path)
                || fm.fileExists(atPath: replacement.restore.path)
        }
        if !artifactsRemain { try? operations.removeItem(manifestURL) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func restore(
        _ replacements: [Replacement],
        expectedBytes: [URL: Data],
        operations: FileOperations
    ) throws {
        let fm = FileManager.default
        var errors: [String] = []

        for replacement in replacements {
            do {
                try removeIfPresent(replacement.restore, operations: operations)
                try operations.copyItem(replacement.backup, replacement.restore)
                if fm.fileExists(atPath: replacement.source.path) {
                    try operations.exchange(replacement.source, replacement.restore)
                } else {
                    try operations.moveItem(replacement.restore, replacement.source)
                }
                guard let expected = expectedBytes[replacement.source],
                      try Data(contentsOf: replacement.source) == expected else {
                    throw MigrationError.restoredBytesChanged(
                        replacement.source.lastPathComponent)
                }
            } catch {
                errors.append("\(replacement.source.lastPathComponent): \(error)")
            }
        }

        guard errors.isEmpty else {
            throw MigrationError.restoreFailures(errors)
        }
    }

    // MARK: - Conversion

    private static func migratedSessionData(_ data: Data) throws -> Data {
        var object = try jsonObject(data)
        object["schemaVersion"] = SessionRecord.currentSchemaVersion
        object.removeValue(forKey: "openedAtUptime")
        let migrated = try encodeJSONObject(object)
        try validateCurrent(migrated, as: .session)
        return migrated
    }

    private static func migratedStationData(
        _ data: Data,
        origin: TimeInterval,
        segmentID: String
    ) throws -> Data {
        var object = try jsonObject(data)
        object["schemaVersion"] = StationRecord.currentSchemaVersion
        object["captureSegmentID"] = segmentID
        object["monotonicTimebase"] = CaptureTimebase.persistedName
        try offsetSummary(in: &object, key: "motion", origin: origin)

        if var swaps = object["sensorSwaps"] as? [[String: Any]] {
            for index in swaps.indices {
                try offsetSummary(in: &swaps[index], key: "motion", origin: origin)
            }
            object["sensorSwaps"] = swaps
        }
        if var brackets = object["brackets"] as? [[String: Any]] {
            for bracketIndex in brackets.indices {
                try offsetSummary(
                    in: &brackets[bracketIndex], key: "motionAtFire", origin: origin)
                guard var frames = brackets[bracketIndex]["frames"] as? [[String: Any]] else {
                    throw MigrationError.invalidJSONObject("brackets.frames")
                }
                for frameIndex in frames.indices {
                    try migrateFrameObject(&frames[frameIndex], origin: origin)
                }
                brackets[bracketIndex]["frames"] = frames
            }
            object["brackets"] = brackets
        }

        let migrated = try encodeJSONObject(object)
        try validateCurrent(migrated, as: .station)
        return migrated
    }

    private static func migratedDarkSettingData(
        _ data: Data,
        origin: TimeInterval
    ) throws -> Data {
        var object = try jsonObject(data)
        guard var frames = object["frames"] as? [[String: Any]] else {
            throw MigrationError.invalidJSONObject("dark.frames")
        }
        for index in frames.indices { try migrateFrameObject(&frames[index], origin: origin) }
        object["frames"] = frames
        let migrated = try encodeJSONObject(object)
        try validateCurrent(migrated, as: .darkSetting)
        return migrated
    }

    private static func migratedUnversionedDarkSettingData(
        _ data: Data,
        origin: TimeInterval
    ) throws -> Data {
        var object = try jsonObject(data)
        guard var frames = object["frames"] as? [[String: Any]] else {
            throw MigrationError.invalidJSONObject("dark.frames")
        }
        for index in frames.indices {
            try renameOptionalRelative(
                in: &frames[index],
                oldKey: "photoTimestampSeconds",
                newKey: "photoTimestampAtSegmentStartSeconds",
                origin: origin)
        }
        object["frames"] = frames
        let migrated = try encodeJSONObject(object)
        try validateCurrent(migrated, as: .darkSetting)
        return migrated
    }

    private static func darkSettingContainsLegacyPhotoTimestamp(_ data: Data) throws -> Bool {
        let object = try jsonObject(data)
        guard let frames = object["frames"] as? [[String: Any]] else {
            throw MigrationError.invalidJSONObject("dark.frames")
        }
        return frames.contains { $0.keys.contains("photoTimestampSeconds") }
    }

    private static func migratedStationV3Data(
        _ data: Data,
        origin: TimeInterval
    ) throws -> Data {
        var object = try jsonObject(data)
        object["schemaVersion"] = StationRecord.currentSchemaVersion
        guard var brackets = object["brackets"] as? [[String: Any]] else {
            throw MigrationError.invalidJSONObject("brackets")
        }
        for bracketIndex in brackets.indices {
            guard var frames = brackets[bracketIndex]["frames"] as? [[String: Any]] else {
                throw MigrationError.invalidJSONObject("brackets.frames")
            }
            for frameIndex in frames.indices {
                try renameOptionalRelative(
                    in: &frames[frameIndex],
                    oldKey: "photoTimestampSeconds",
                    newKey: "photoTimestampAtSegmentStartSeconds",
                    origin: origin)
            }
            brackets[bracketIndex]["frames"] = frames
        }
        object["brackets"] = brackets
        let migrated = try encodeJSONObject(object)
        try validateCurrent(migrated, as: .station)
        return migrated
    }

    private static func migratedMotionData(
        _ data: Data,
        origin: TimeInterval
    ) throws -> Data {
        let lines = try rawMotionLines(from: data)
        var output = Data()
        for line in lines {
            _ = try decoder.decode(LegacyMotionSample.self, from: line)
            var object = try jsonObject(line)
            let raw = try requiredNumber(object.removeValue(forKey: "t"), key: "t")
            object["secondsSinceSegmentStart"] = relative(raw, origin: origin)
            output.append(try encodeJSONObject(object, prettyPrinted: false))
            output.append(0x0A)
        }
        try validateCurrent(output, as: .motionStream)
        return output
    }

    private static func migrateFrameObject(
        _ frame: inout [String: Any],
        origin: TimeInterval
    ) throws {
        let capture = try requiredNumber(
            frame.removeValue(forKey: "capturedAtUptime"), key: "capturedAtUptime")
        frame["capturedAtSegmentStartSeconds"] = relative(capture, origin: origin)
        try renameOptionalRelative(
            in: &frame,
            oldKey: "uptimeAtDelivery",
            newKey: "deliveredAtSegmentStartSeconds",
            origin: origin)
        try renameOptionalRelative(
            in: &frame,
            oldKey: "latestMotionTimestamp",
            newKey: "latestMotionAtSegmentStartSeconds",
            origin: origin)
        try renameOptionalRelative(
            in: &frame,
            oldKey: "photoTimestampSeconds",
            newKey: "photoTimestampAtSegmentStartSeconds",
            origin: origin)
        try offsetSummary(in: &frame, key: "motion", origin: origin)
        try offsetSummary(in: &frame, key: "motionNeighbourhood", origin: origin)
    }

    private static func renameOptionalRelative(
        in object: inout [String: Any],
        oldKey: String,
        newKey: String,
        origin: TimeInterval
    ) throws {
        guard let value = object.removeValue(forKey: oldKey) else { return }
        if value is NSNull {
            object[newKey] = value
        } else {
            object[newKey] = relative(
                try requiredNumber(value, key: oldKey), origin: origin)
        }
    }

    private static func offsetSummary(
        in object: inout [String: Any],
        key: String,
        origin: TimeInterval
    ) throws {
        guard let value = object[key], !(value is NSNull) else { return }
        guard var summary = value as? [String: Any] else {
            throw MigrationError.invalidJSONObject(key)
        }
        summary["windowStart"] = relative(
            try requiredNumber(summary["windowStart"], key: "\(key).windowStart"),
            origin: origin)
        summary["windowEnd"] = relative(
            try requiredNumber(summary["windowEnd"], key: "\(key).windowEnd"),
            origin: origin)
        object[key] = summary
    }

    private static func relative(_ uptime: TimeInterval, origin: TimeInterval) -> TimeInterval {
        max(0, uptime - origin)
    }

    // MARK: - Validation and JSONL

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func validateCurrent(_ data: Data, as kind: MetadataKind) throws {
        switch kind {
        case .session:
            _ = try decoder.decode(SessionRecord.self, from: data)
        case .station:
            _ = try decoder.decode(StationRecord.self, from: data)
        case .darkSetting:
            _ = try decoder.decode(DarkSettingRecord.self, from: data)
        case .motionStream:
            _ = try decodeMotionLines(MotionSample.self, from: data)
        }
    }

    private static func decodeMotionLines<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> [T] {
        try rawMotionLines(from: data).map { try decoder.decode(type, from: $0) }
    }

    private static func rawMotionLines(from data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        var pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if pieces.last?.isEmpty == true { pieces.removeLast() }
        guard !pieces.contains(where: { $0.isEmpty }) else {
            throw MigrationError.emptyMotionLine
        }
        return pieces.map { Data($0) }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.invalidJSONObject("top level")
        }
        return object
    }

    private static func encodeJSONObject(
        _ object: [String: Any],
        prettyPrinted: Bool = true
    ) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if prettyPrinted { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    private static func requiredNumber(_ value: Any?, key: String) throws -> Double {
        guard let number = value as? NSNumber else {
            throw MigrationError.invalidNumber(key)
        }
        return number.doubleValue
    }

    // MARK: - Files and logs

    private static func sessionDirectories(
        at root: URL,
        operations: FileOperations
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        var directories: [URL] = []
        for url in urls {
            if try operations.isDirectory(url) { directories.append(url) }
        }
        return directories.sorted(by: pathOrder)
    }

    private static func quarantineLegacyLogs(
        at root: URL,
        operations: FileOperations
    ) throws -> LogCleanupPlan? {
        let fm = FileManager.default
        let quarantineURL = root.appendingPathComponent(logQuarantineName, isDirectory: true)
        let manifestURL = quarantineURL.appendingPathComponent(logCleanupManifestName)
        guard fm.fileExists(atPath: root.path) else { return nil }

        let manifest: LogCleanupManifest
        if fm.fileExists(atPath: manifestURL.path) {
            manifest = try loadLogCleanupManifest(from: manifestURL)
        } else if fm.fileExists(atPath: quarantineURL.path) {
            let entries = try fm.contentsOfDirectory(
                at: quarantineURL, includingPropertiesForKeys: nil)
            guard entries.isEmpty else { throw MigrationError.invalidLogCleanupManifest }
            try operations.removeItem(quarantineURL)
            return try quarantineLegacyLogs(at: root, operations: operations)
        } else {
            let urls = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
            let legacyURLs = try urls.filter { url in
                guard url.pathExtension == "log" else { return false }
                return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }.sorted(by: pathOrder)
            guard !legacyURLs.isEmpty else { return nil }
            let entries = try legacyURLs.map { url -> LogCleanupManifest.Entry in
                let data = try Data(contentsOf: url)
                return LogCleanupManifest.Entry(
                    name: url.lastPathComponent,
                    byteCount: data.count,
                    sha256: sha256(data))
            }
            manifest = LogCleanupManifest(entries: entries)
            try fm.createDirectory(at: quarantineURL, withIntermediateDirectories: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try operations.writeAtomically(encoder.encode(manifest), manifestURL)
        }

        for entry in manifest.entries {
            let source = root.appendingPathComponent(entry.name)
            let quarantined = quarantineURL.appendingPathComponent(entry.name)
            if fm.fileExists(atPath: quarantined.path) {
                try validateFingerprint(
                    Data(contentsOf: quarantined),
                    byteCount: entry.byteCount,
                    sha256: entry.sha256,
                    error: .quarantinedLogChanged(entry.name))
                continue
            }
            guard fm.fileExists(atPath: source.path) else {
                throw MigrationError.missingQuarantinedLog(entry.name)
            }
            try validateFingerprint(
                Data(contentsOf: source),
                byteCount: entry.byteCount,
                sha256: entry.sha256,
                error: .legacyLogChanged(entry.name))
            try operations.moveItem(source, quarantined)
            try validateFingerprint(
                Data(contentsOf: quarantined),
                byteCount: entry.byteCount,
                sha256: entry.sha256,
                error: .quarantinedLogChanged(entry.name))
        }
        return LogCleanupPlan(quarantineURL: quarantineURL, entryCount: manifest.entries.count)
    }

    private static func finishCommittedLogCleanup(
        at root: URL,
        operations: FileOperations
    ) throws -> Int {
        let quarantineURL = root.appendingPathComponent(logQuarantineName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: quarantineURL.path) else { return 0 }
        let manifest = try loadLogCleanupManifest(
            from: quarantineURL.appendingPathComponent(logCleanupManifestName))
        try operations.removeItem(quarantineURL)
        return manifest.entries.count
    }

    private static func loadLogCleanupManifest(from url: URL) throws -> LogCleanupManifest {
        let manifest = try JSONDecoder().decode(
            LogCleanupManifest.self, from: Data(contentsOf: url))
        guard manifest.format == "rawforge.privacy-log-cleanup",
              manifest.schemaVersion == 1,
              manifest.migrationVersion == migrationVersion else {
            throw MigrationError.invalidLogCleanupManifest
        }
        var names = Set<String>()
        for entry in manifest.entries {
            guard entry.name == URL(fileURLWithPath: entry.name).lastPathComponent,
                  entry.name != ".", entry.name != "..",
                  entry.name.hasSuffix(".log"),
                  names.insert(entry.name).inserted else {
                throw MigrationError.invalidLogCleanupManifest
            }
        }
        return manifest
    }

    private static func atomicExchange(_ source: URL, _ replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            source,
            withItemAt: replacement,
            backupItemName: nil,
            options: [])
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func removeIfPresent(
        _ url: URL,
        operations: FileOperations
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try operations.removeItem(url)
        }
    }

    private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent < rhs.lastPathComponent
    }

    private static func metadataKind(for source: URL) throws -> MetadataKind {
        switch source.lastPathComponent {
        case "session.json": return .session
        case let name where name.hasPrefix("station-") && source.pathExtension == "json":
            return .station
        case let name where name.hasPrefix("dark-") && source.pathExtension == "json":
            return .darkSetting
        case let name where name.hasPrefix("motion-") && source.pathExtension == "jsonl":
            return .motionStream
        default:
            throw MigrationError.unknownBackup(source.lastPathComponent)
        }
    }

    private enum MigrationError: Error, CustomStringConvertible {
        case missingSessionHeader
        case legacyStationWithoutAnchor(String)
        case legacyDarkSettingWithoutAnchor(String)
        case invalidJSONObject(String)
        case invalidNumber(String)
        case emptyMotionLine
        case stagedBytesChanged(String)
        case backupBytesChanged(String)
        case exchangedBytesChanged(String)
        case restoredBytesChanged(String)
        case rollbackFailed(exchangeError: String, rollbackError: String)
        case restoreFailures([String])
        case backupCleanupFailed(String)
        case unknownBackup(String)
        case transactionArtifactAlreadyExists(String)
        case sourceChangedBeforeCommit(String)
        case incompleteBackupSet(String)
        case invalidTransactionManifest
        case invalidTransactionState(String)
        case unownedBackup(String)
        case committedSourceChanged(String)
        case invalidLogCleanupManifest
        case missingQuarantinedLog(String)
        case legacyLogChanged(String)
        case quarantinedLogChanged(String)

        var description: String {
            switch self {
            case .missingSessionHeader:
                return "session.json is missing"
            case .legacyStationWithoutAnchor(let name):
                return "\(name) is legacy but session schema 4's openedAtUptime is unavailable"
            case .legacyDarkSettingWithoutAnchor(let name):
                return "\(name) contains legacy photoTimestampSeconds but the session anchor "
                    + "is unavailable"
            case .invalidJSONObject(let key):
                return "invalid JSON object at \(key)"
            case .invalidNumber(let key):
                return "invalid timing value at \(key)"
            case .emptyMotionLine:
                return "motion stream contains an empty line"
            case .stagedBytesChanged(let name):
                return "staged bytes changed for \(name)"
            case .backupBytesChanged(let name):
                return "backup bytes changed for \(name)"
            case .exchangedBytesChanged(let name):
                return "exchanged bytes changed for \(name)"
            case .restoredBytesChanged(let name):
                return "restored bytes changed for \(name)"
            case .rollbackFailed(let exchangeError, let rollbackError):
                return "exchange failed (\(exchangeError)); rollback failed (\(rollbackError))"
            case .restoreFailures(let failures):
                return "restore failed: \(failures.joined(separator: "; "))"
            case .backupCleanupFailed(let error):
                return "valid replacements installed but backup cleanup failed: \(error)"
            case .unknownBackup(let name):
                return "unrecognized privacy backup \(name)"
            case .transactionArtifactAlreadyExists(let name):
                return "privacy transaction artifact already exists for \(name)"
            case .sourceChangedBeforeCommit(let name):
                return "source changed before privacy transaction commit for \(name)"
            case .incompleteBackupSet(let name):
                return "privacy transaction backup set is incomplete at \(name)"
            case .invalidTransactionManifest:
                return "invalid privacy transaction manifest"
            case .invalidTransactionState(let state):
                return "unsupported privacy transaction state \(state)"
            case .unownedBackup(let name):
                return "privacy backup has no complete transaction manifest: \(name)"
            case .committedSourceChanged(let name):
                return "committed privacy migration source changed for \(name)"
            case .invalidLogCleanupManifest:
                return "invalid privacy log cleanup manifest"
            case .missingQuarantinedLog(let name):
                return "legacy log is missing during quarantine: \(name)"
            case .legacyLogChanged(let name):
                return "legacy log changed during quarantine: \(name)"
            case .quarantinedLogChanged(let name):
                return "quarantined legacy log changed: \(name)"
            }
        }
    }
}

// MARK: - Legacy schema 4 / schema 2 DTOs

private struct RecordEnvelope: Decodable {
    let format: String
    let schemaVersion: Int
}

private struct LegacySessionV4: Decodable {
    let format: String
    let schemaVersion: Int
    let sessionType: String
    let calibrationSessionId: String?
    let calibrationAgeSeconds: Double?
    let thermalStateAtOpen: String
    let sessionId: String
    let openedAt: Date
    let openedAtUptime: TimeInterval
    let capability: CapabilityReport
    let availableCapacityBytesAtOpen: Int64?
    let capacityMeasuredWith: String
    let deviceProfile: DeviceProfile?
    let excluded: [SessionRecord.Exclusion]
}

private struct LegacyStationV2: Decodable {
    let format: String
    let schemaVersion: Int
    let stationIndex: Int
    let sessionId: String
    let openedAt: Date
    let closedAt: Date
    let brackets: [LegacyBracketRecord]
    let poseIntent: String?
    let estimatedSeconds: Double?
    let sensorSwaps: [LegacySwapRecord]
    let motion: MotionSummary?
    let motionStreamFile: String?
    let motionRequestedHz: Double?
}

private struct LegacySwapRecord: Decodable {
    let fromSensor: String?
    let toSensor: String
    let durationSeconds: Double
    let motion: MotionSummary?
}

private struct LegacyBracketRecord: Decodable {
    let bracketIndex: Int
    let sensor: String
    let sensorUniqueID: String?
    let captureSet: CaptureSet?
    let renderedSpecs: [CaptureSpec]?
    let evOffsetStops: Double?
    let executionMode: String?
    let bracketRequestSizes: [Int]?
    let droppedRungs: [DroppedRung]
    let minimumInterFrameGapSeconds: Double?
    let stillnessSettled: Bool?
    let stillnessWaitSeconds: Double?
    let motionAtFire: MotionSummary?
    let dwellSeconds: Double?
    let note: String?
    let frames: [LegacyFrameRecord]
}

private struct LegacyFrameRecord: Decodable {
    let frameIndex: Int
    let filename: String
    let sensor: String
    let requested: FrameRecord.Exposure
    let deviceAchieved: FrameRecord.Exposure?
    let photoAchieved: FrameRecord.Exposure?
    let dng: FrameRecord.DNGWitness
    let focus: FrameRecord.Focus?
    let zoomFactor: Double?
    let capturedAtUptime: TimeInterval
    let capturedAt: Date
    let photoTimestampSeconds: Double?
    let gapFromPreviousSeconds: TimeInterval?
    let clipping: ClippingStats?
    let motion: MotionSummary?
    let motionNeighbourhood: MotionSummary?
    let uptimeAtDelivery: TimeInterval?
    let latestMotionTimestamp: TimeInterval?
}

private struct LegacyDarkSettingRecord: Decodable {
    let sensor: String
    let shutterSeconds: Double
    let iso: Float
    let requestedRepeats: Int
    let frames: [LegacyFrameRecord]
    let rejections: [DarkFrameRejection]
    let aborted: Bool
    let abortReason: String?
}

private struct LegacyMotionSample: Decodable {
    let t: TimeInterval
    let gx: Double
    let gy: Double
    let gz: Double
    let ax: Double
    let ay: Double
    let az: Double
}

// MARK: - Versioned marker and launch notice

private struct PrivacyMigrationMarker: Codable {
    enum NoticeState: String, Codable {
        case none
        case pending
        case acknowledged
    }

    var format = "rawforge.privacy-migration"
    var schemaVersion = 1
    var completedMigrationVersion: Int?
    var logsClearedMigrationVersion: Int?
    var noticeState: NoticeState = .none
}

private enum PrivacyMigrationMarkerStore {
    private struct Envelope: Decodable {
        let format: String
        let schemaVersion: Int
    }

    static func load(from url: URL) throws -> PrivacyMigrationMarker {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PrivacyMigrationMarker()
        }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "rawforge.privacy-migration", envelope.schemaVersion == 1 else {
            throw MarkerError.unsupported(envelope.format, envelope.schemaVersion)
        }
        return try JSONDecoder().decode(PrivacyMigrationMarker.self, from: data)
    }

    static func save(
        _ marker: PrivacyMigrationMarker,
        to url: URL,
        writeAtomically: (_ data: Data, _ url: URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(encoder.encode(marker), url)
    }

    private enum MarkerError: Error, CustomStringConvertible {
        case unsupported(String, Int)

        var description: String {
            switch self {
            case .unsupported(let format, let schema):
                return "unsupported marker \(format) schema \(schema)"
            }
        }
    }
}

@MainActor
final class LaunchNoticeStore: ObservableObject {
    static let privacyMigrationMessage =
        "Earlier diagnostic logs were cleared so RAWForge no longer retains the phone's "
        + "boot-time clock. Captures and DNG files were not removed."

    @Published private(set) var message: String?
    private let markerURL: URL

    init(markerURL: URL, orphanedFramesRemoved: Int) {
        self.markerURL = markerURL
        let marker = try? PrivacyMigrationMarkerStore.load(from: markerURL)
        message = marker?.noticeState == .pending
            ? Self.noticeMessage(orphanedFramesRemoved: orphanedFramesRemoved)
            : nil
    }

    private static func noticeMessage(orphanedFramesRemoved: Int) -> String {
        guard orphanedFramesRemoved > 0 else { return privacyMigrationMessage }
        let file = orphanedFramesRemoved == 1 ? "file" : "files"
        return "Earlier diagnostic logs were cleared so RAWForge no longer retains the phone's "
            + "boot-time clock. Separately, launch cleanup removed \(orphanedFramesRemoved) "
            + "orphaned DNG \(file) with no owning station metadata."
    }

    func acknowledge() {
        guard message != nil,
              var marker = try? PrivacyMigrationMarkerStore.load(from: markerURL) else { return }
        marker.noticeState = .acknowledged
        do {
            try PrivacyMigrationMarkerStore.save(marker, to: markerURL)
            message = nil
        } catch {
            // Keep the notice pending so a failed acknowledgement cannot become silent.
        }
    }
}
