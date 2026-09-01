import Combine
import Foundation

/// Upgrades the one shipped metadata generation that persisted raw system uptime.
///
/// A session directory is the transaction boundary. Every recognized replacement is
/// decoded, staged, read back, and decoded as its current type before the first source
/// is exchanged. Sibling backups make a later exchange or validation failure reversible.
enum RecordPrivacyMigrator {
    static let migrationVersion = 1

    typealias Exchange = (_ source: URL, _ replacement: URL) throws -> Void

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
        exchange: @escaping Exchange = atomicExchange
    ) -> Report {
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
            directories = try sessionDirectories(at: sessionsRoot)
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
                    exchange: exchange
                ) {
                    report.migratedSessions += 1
                }
            } catch {
                report.failures.append("\(directory.lastPathComponent): \(error)")
            }
            report.untouchedUnknownRecords += sessionUnknownRecords
        }

        if updatedMarker.logsClearedMigrationVersion != migrationVersion {
            let cleanup = removeLegacyLogs(at: logsRoot)
            report.removedLogs = cleanup.removed
            report.failures.append(contentsOf: cleanup.failures)
            if cleanup.failures.isEmpty {
                updatedMarker.logsClearedMigrationVersion = migrationVersion
                if cleanup.removed > 0, updatedMarker.noticeState == .none {
                    updatedMarker.noticeState = .pending
                }
            }
        }

        if report.failures.isEmpty, report.untouchedUnknownRecords == 0 {
            updatedMarker.completedMigrationVersion = migrationVersion
        } else {
            updatedMarker.completedMigrationVersion = nil
        }

        do {
            try PrivacyMigrationMarkerStore.save(updatedMarker, to: markerURL)
        } catch {
            report.failures.append("privacy migration marker: \(error)")
        }
        return report
    }

    private enum MetadataKind: Equatable {
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
        var restore: URL { source.appendingPathExtension("privacy-restore") }
    }

    private static func migrateSession(
        in directory: URL,
        unknownRecords: inout Int,
        exchange: @escaping Exchange
    ) throws -> Bool {
        try recoverInterruptedTransaction(in: directory, exchange: exchange)

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
            case (StationRecord.currentFormat, StationRecord.currentSchemaVersion):
                try validateCurrent(data, as: .station)
            default:
                unknownRecords += 1
            }
        }

        if let origin = legacyOrigin {
            for url in darkURLs {
                let data = try Data(contentsOf: url)
                if (try? decoder.decode(DarkSettingRecord.self, from: data)) != nil {
                    try validateCurrent(data, as: .darkSetting)
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
                try validateCurrent(Data(contentsOf: url), as: .darkSetting)
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

        try transact(replacements.sorted { pathOrder($0.source, $1.source) }, exchange: exchange)
        return true
    }

    // MARK: - Transaction

    private static func transact(
        _ replacements: [Replacement],
        exchange: @escaping Exchange
    ) throws {
        let fm = FileManager.default
        var staged: [Replacement] = []
        do {
            for replacement in replacements {
                try removeIfPresent(replacement.staged)
                try replacement.data.write(to: replacement.staged, options: .atomic)
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

        var originals: [URL: Data] = [:]
        var backedUp: [Replacement] = []
        do {
            for replacement in replacements {
                try removeIfPresent(replacement.backup)
                let original = try Data(contentsOf: replacement.source)
                originals[replacement.source] = original
                try fm.copyItem(at: replacement.source, to: replacement.backup)
                guard try Data(contentsOf: replacement.backup) == original else {
                    throw MigrationError.backupBytesChanged(replacement.source.lastPathComponent)
                }
                backedUp.append(replacement)
            }
        } catch {
            for replacement in replacements { try? fm.removeItem(at: replacement.staged) }
            for replacement in backedUp { try? fm.removeItem(at: replacement.backup) }
            throw error
        }

        do {
            for replacement in replacements {
                try exchange(replacement.source, replacement.staged)
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
        } catch {
            do {
                try restore(
                    replacements,
                    expectedBytes: originals,
                    exchange: exchange,
                    removeBackupsAfterValidation: true)
            } catch let rollbackError {
                throw MigrationError.rollbackFailed(
                    exchangeError: String(describing: error),
                    rollbackError: String(describing: rollbackError))
            }
            throw error
        }

        do {
            // The session header owns the offset anchor, so its backup is the last
            // one removed. An interruption during cleanup can therefore always
            // restore that anchor before retrying any remaining child backup.
            let cleanupOrder = replacements.sorted {
                if $0.kind == .session { return false }
                if $1.kind == .session { return true }
                return pathOrder($0.source, $1.source)
            }
            for replacement in cleanupOrder { try fm.removeItem(at: replacement.backup) }
        } catch {
            // Current files are valid, and the retained backups let the next launch
            // restore and retry the directory before any normal store reads it.
            throw MigrationError.backupCleanupFailed(String(describing: error))
        }
    }

    private static func recoverInterruptedTransaction(
        in directory: URL,
        exchange: @escaping Exchange
    ) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = files.filter { $0.lastPathComponent.hasSuffix(".privacy-backup") }
            .sorted(by: pathOrder)

        if !backups.isEmpty {
            let replacements = try backups.map { backup -> Replacement in
                let sourceName = String(
                    backup.lastPathComponent.dropLast(".privacy-backup".count))
                let source = directory.appendingPathComponent(sourceName)
                return Replacement(
                    source: source,
                    data: try Data(contentsOf: backup),
                    kind: try metadataKind(for: source))
            }
            try restore(
                replacements,
                expectedBytes: Dictionary(uniqueKeysWithValues: replacements.map {
                    ($0.source, $0.data)
                }),
                exchange: exchange,
                removeBackupsAfterValidation: true)
        }

        let leftovers = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers where url.lastPathComponent.hasSuffix(".privacy-migration")
                || url.lastPathComponent.hasSuffix(".privacy-restore") {
            try fm.removeItem(at: url)
        }
    }

    private static func restore(
        _ replacements: [Replacement],
        expectedBytes: [URL: Data],
        exchange: @escaping Exchange,
        removeBackupsAfterValidation: Bool
    ) throws {
        let fm = FileManager.default
        var errors: [String] = []

        for replacement in replacements {
            do {
                try removeIfPresent(replacement.restore)
                try fm.copyItem(at: replacement.backup, to: replacement.restore)
                if fm.fileExists(atPath: replacement.source.path) {
                    try exchange(replacement.source, replacement.restore)
                } else {
                    try fm.moveItem(at: replacement.restore, to: replacement.source)
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
        if removeBackupsAfterValidation {
            for replacement in replacements {
                try fm.removeItem(at: replacement.backup)
                try? fm.removeItem(at: replacement.staged)
                try? fm.removeItem(at: replacement.restore)
            }
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

    private static func sessionDirectories(at root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted(by: pathOrder)
    }

    private static func removeLegacyLogs(at root: URL) -> (removed: Int, failures: [String]) {
        guard FileManager.default.fileExists(atPath: root.path) else { return (0, []) }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
        } catch {
            return (0, ["legacy logs discovery: \(error)"])
        }
        var removed = 0
        var failures: [String] = []
        for url in urls.filter({ $0.pathExtension == "log" }).sorted(by: pathOrder) {
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    continue
                }
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                failures.append("legacy log \(url.lastPathComponent): \(error)")
            }
        }
        return (removed, failures)
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

        var description: String {
            switch self {
            case .missingSessionHeader:
                return "session.json is missing"
            case .legacyStationWithoutAnchor(let name):
                return "\(name) is legacy but session schema 4's openedAtUptime is unavailable"
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

    static func save(_ marker: PrivacyMigrationMarker, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: url, options: .atomic)
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

    init(markerURL: URL) {
        self.markerURL = markerURL
        let marker = try? PrivacyMigrationMarkerStore.load(from: markerURL)
        message = marker?.noticeState == .pending ? Self.privacyMigrationMessage : nil
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
