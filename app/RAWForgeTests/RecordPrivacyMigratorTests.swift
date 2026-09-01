import Foundation
import XCTest
@testable import RAWForge

final class RecordPrivacyMigratorTests: XCTestCase {
    private let fm = FileManager.default

    func testLegacySessionMetadataBecomesSegmentRelativeWithoutTouchingDNG() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        let beforeDNG = try Data(contentsOf: fixture.dngURL)

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 1)
        XCTAssertEqual(report.removedLogs, 2)
        XCTAssertEqual(report.untouchedUnknownRecords, 0)
        XCTAssertTrue(report.failures.isEmpty)

        let session = try fixture.currentSession()
        XCTAssertEqual(session.schemaVersion, 5)
        let sessionText = String(decoding: try Data(contentsOf: fixture.sessionURL), as: UTF8.self)
        XCTAssertFalse(sessionText.contains("openedAtUptime"))

        let station = try fixture.currentStation()
        XCTAssertEqual(station.schemaVersion, 3)
        XCTAssertEqual(station.monotonicTimebase, CaptureTimebase.persistedName)
        XCTAssertNotNil(station.captureSegmentID)
        let frame = try XCTUnwrap(station.brackets.first?.frames.first)
        XCTAssertEqual(frame.capturedAtSegmentStartSeconds, 3, accuracy: 0.000_001)
        XCTAssertEqual(frame.deliveredAtSegmentStartSeconds ?? -1, 3.25, accuracy: 0.000_001)
        XCTAssertEqual(frame.latestMotionAtSegmentStartSeconds ?? -1, 2.75, accuracy: 0.000_001)
        assertWindow(station.motion, 1, 4)
        assertWindow(station.sensorSwaps.first?.motion, 0.5, 0.9)
        assertWindow(station.brackets.first?.motionAtFire, 2, 3)
        assertWindow(frame.motion, 2.8, 3)
        assertWindow(frame.motionNeighbourhood, 2.5, 3.5)

        let dark = try fixture.currentDarkSetting()
        let darkFrame = try XCTUnwrap(dark.frames.first)
        XCTAssertEqual(darkFrame.capturedAtSegmentStartSeconds, 0, accuracy: 0.000_001)
        XCTAssertEqual(darkFrame.latestMotionAtSegmentStartSeconds ?? -1, 1, accuracy: 0.000_001)
        assertWindow(darkFrame.motion, 0, 0.5)

        let samples = try fixture.currentMotionSamples()
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].secondsSinceSegmentStart, 0, accuracy: 0.000_001)
        XCTAssertEqual(samples[1].secondsSinceSegmentStart, 2.9, accuracy: 0.000_001)
        XCTAssertEqual(samples[2].secondsSinceSegmentStart, 3.1, accuracy: 0.000_001)
        XCTAssertEqual(try Data(contentsOf: fixture.dngURL), beforeDNG)
        XCTAssertFalse(fm.fileExists(atPath: fixture.logsRoot.appendingPathComponent("old-a.log").path))
        XCTAssertFalse(fm.fileExists(atPath: fixture.logsRoot.appendingPathComponent("old-b.log").path))
        XCTAssertTrue(fm.fileExists(atPath: fixture.logsRoot.appendingPathComponent(".running").path))
        XCTAssertTrue(fm.fileExists(atPath: fixture.logsRoot.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(fm.fileExists(
            atPath: fixture.logsRoot.appendingPathComponent("archive.log/keep.txt").path),
            "only legacy .log files may be removed")
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)

        let marker = try fixture.markerObject()
        XCTAssertEqual(marker["schemaVersion"] as? Int, 1)
        XCTAssertEqual(marker["completedMigrationVersion"] as? Int, 1)
        XCTAssertEqual(marker["logsClearedMigrationVersion"] as? Int, 1)
        XCTAssertEqual(marker["noticeState"] as? String, "pending")
    }

    func testSecondRunIsACompleteNoOpAndPreservesNewRelativeLog() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        _ = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)
        let firstBytes = try fixture.allMetadataBytes()
        let currentLog = fixture.logsRoot.appendingPathComponent("rawforge-current.log")
        try Data("+0.100s INFO app current".utf8).write(to: currentLog)

        let second = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(second.migratedSessions, 0)
        XCTAssertEqual(second.removedLogs, 0)
        XCTAssertEqual(second.untouchedUnknownRecords, 0)
        XCTAssertTrue(second.failures.isEmpty)
        XCTAssertEqual(try fixture.allMetadataBytes(), firstBytes)
        XCTAssertEqual(try Data(contentsOf: currentLog), Data("+0.100s INFO app current".utf8))
    }

    func testMalformedRecognizedMetadataLeavesEveryOriginalByteUntouched() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        try fixture.corruptStationJSON()
        let before = try fixture.allMetadataBytes()
        let beforeDNG = try Data(contentsOf: fixture.dngURL)

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertEqual(try Data(contentsOf: fixture.dngURL), beforeDNG)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])
    }

    func testMalformedLegacyMotionLineLeavesEveryOriginalByteUntouched() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        try Data(#"{"t":503,"gx":1}"#.utf8).write(to: fixture.motionURL)
        let before = try fixture.allMetadataBytes()

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
    }

    func testExchangeFailureRollsBackEverySourceAndValidatesOriginalBytes() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        let before = try fixture.allMetadataBytes()
        var exchangeCount = 0

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL,
            exchange: { source, replacement in
                exchangeCount += 1
                if exchangeCount == 2 { throw InjectedFailure.exchange }
                _ = try FileManager.default.replaceItemAt(source, withItemAt: replacement)
            })

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertGreaterThan(exchangeCount, 2, "rollback must exchange backups back into place")
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])
    }

    func testInterruptedBackupCreationCannotPublishPartialBackup() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        let before = try fixture.allMetadataBytes()
        var operations = RecordPrivacyMigrator.FileOperations.live
        let copyItem = operations.copyItem
        let writeAtomically = operations.writeAtomically
        var copyCount = 0
        var interruptedBackupURL: URL?
        var preparingManifestData: Data?
        operations.writeAtomically = { data, url in
            if url.lastPathComponent == ".privacy-metadata-transaction-v1.json" {
                preparingManifestData = data
            }
            try writeAtomically(data, url)
        }
        operations.copyItem = { source, destination in
            copyCount += 1
            if copyCount == 2 {
                interruptedBackupURL = destination
                try Data("partial backup".utf8).write(to: destination)
                throw InjectedFailure.backupCreation
            }
            try copyItem(source, destination)
        }

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL,
            operations: operations)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(copyCount, 2)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])

        let manifestURL = fixture.sessionDirectory.appendingPathComponent(
            ".privacy-metadata-transaction-v1.json")
        try XCTUnwrap(preparingManifestData).write(to: manifestURL, options: .atomic)
        let partialURL = try XCTUnwrap(interruptedBackupURL)
        try Data("crash-truncated backup".utf8).write(to: partialURL)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertEqual(
            try fixture.privacyArtifacts(),
            [".privacy-metadata-transaction-v1.json", partialURL.lastPathComponent].sorted())
        XCTAssertEqual(try fixture.transactionState(), "preparing")

        let recovered = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(recovered.migratedSessions, 1)
        XCTAssertTrue(recovered.failures.isEmpty)
        XCTAssertEqual(try fixture.currentSession().schemaVersion, 5)
        XCTAssertEqual(try fixture.currentStation().schemaVersion, 3)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
        XCTAssertEqual(try fixture.markerObject()["completedMigrationVersion"] as? Int, 1)
    }

    func testCommittedTransactionWithPartialBackupCleanupKeepsEveryCurrentSource() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        let originalBytes = try fixture.allMetadataBytes()
        var operations = RecordPrivacyMigrator.FileOperations.live
        let removeItem = operations.removeItem
        var backupRemovalCount = 0
        operations.removeItem = { url in
            if url.lastPathComponent.hasSuffix(".privacy-backup") {
                backupRemovalCount += 1
                if backupRemovalCount == 2 { throw InjectedFailure.backupCleanup }
            }
            try removeItem(url)
        }

        let interrupted = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL,
            operations: operations)

        XCTAssertEqual(interrupted.migratedSessions, 0)
        XCTAssertEqual(interrupted.failures.count, 1)
        XCTAssertEqual(backupRemovalCount, 2)
        let installedBytes = try fixture.allMetadataBytes()
        XCTAssertNotEqual(installedBytes, originalBytes)
        XCTAssertEqual(try fixture.currentSession().schemaVersion, 5)
        XCTAssertEqual(try fixture.currentStation().schemaVersion, 3)
        let interruptedArtifacts = try fixture.privacyArtifacts()
        XCTAssertTrue(interruptedArtifacts.contains(".privacy-metadata-transaction-v1.json"))
        XCTAssertEqual(
            interruptedArtifacts.filter { $0.hasSuffix(".privacy-backup") }.count,
            3)
        XCTAssertEqual(try fixture.transactionState(), "committed")
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])

        let recovered = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(recovered.migratedSessions, 0)
        XCTAssertTrue(recovered.failures.isEmpty)
        XCTAssertEqual(try fixture.allMetadataBytes(), installedBytes)
        XCTAssertNotEqual(try fixture.allMetadataBytes(), originalBytes)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
        XCTAssertEqual(try fixture.markerObject()["completedMigrationVersion"] as? Int, 1)
    }

    func testMarkerSaveFailureAfterLogQuarantinePreservesNewRelativeLogOnRetry() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        let oldABytes = try Data(contentsOf: fixture.logsRoot.appendingPathComponent("old-a.log"))
        let oldBBytes = try Data(contentsOf: fixture.logsRoot.appendingPathComponent("old-b.log"))
        var operations = RecordPrivacyMigrator.FileOperations.live
        let writeAtomically = operations.writeAtomically
        var markerWriteCount = 0
        operations.writeAtomically = { data, url in
            if url.standardizedFileURL == fixture.markerURL.standardizedFileURL {
                markerWriteCount += 1
                throw InjectedFailure.markerSave
            }
            try writeAtomically(data, url)
        }

        let interrupted = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL,
            operations: operations)

        XCTAssertEqual(interrupted.migratedSessions, 1)
        XCTAssertEqual(interrupted.removedLogs, 0)
        XCTAssertEqual(interrupted.failures.count, 1)
        XCTAssertEqual(markerWriteCount, 1)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])
        XCTAssertEqual(try fixture.logPrivacyArtifacts(), [".privacy-log-cleanup-v1"])
        XCTAssertEqual(try Data(contentsOf: fixture.quarantinedLog("old-a.log")), oldABytes)
        XCTAssertEqual(try Data(contentsOf: fixture.quarantinedLog("old-b.log")), oldBBytes)
        let currentLog = fixture.logsRoot.appendingPathComponent("rawforge-current.log")
        let currentLogBytes = Data("+0.100s INFO app current".utf8)
        try currentLogBytes.write(to: currentLog)

        let recovered = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(recovered.migratedSessions, 0)
        XCTAssertEqual(recovered.removedLogs, 2)
        XCTAssertTrue(recovered.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: currentLog), currentLogBytes)
        XCTAssertTrue(try fixture.logPrivacyArtifacts().isEmpty)
        let marker = try fixture.markerObject()
        XCTAssertEqual(marker["completedMigrationVersion"] as? Int, 1)
        XCTAssertEqual(marker["logsClearedMigrationVersion"] as? Int, 1)
        XCTAssertEqual(marker["noticeState"] as? String, "pending")
    }

    func testUnknownStationBlocksItsLegacySessionAndRemainsByteIdentical() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        try fixture.setStationSchema(999)
        let before = try fixture.allMetadataBytes()

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.untouchedUnknownRecords, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])
    }

    func testUnknownSchemaIsStillReportedWhenAnotherRecognizedFileIsMalformed() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        try fixture.setStationSchema(999)
        try fixture.corruptDarkJSON()
        let before = try fixture.allMetadataBytes()

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.untouchedUnknownRecords, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])
    }

    func testUnknownSessionIsReportedAndUntouched() throws {
        let fixture = try MigrationFixture.unknownSession(schemaVersion: 999)
        defer { fixture.remove() }
        let before = try fixture.allMetadataBytes()

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.untouchedUnknownRecords, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertNil(try fixture.markerObject()["completedMigrationVersion"])
    }

    func testUnreadableSessionsRootIsFailureAndCannotBeMarkedComplete() throws {
        let root = fm.temporaryDirectory.appendingPathComponent(
            "RecordPrivacyMigratorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionsRoot = root.appendingPathComponent("sessions")
        let logsRoot = root.appendingPathComponent("logs", isDirectory: true)
        let markerURL = root.appendingPathComponent("support/privacy-migration-v1.json")
        try Data("not a directory".utf8).write(to: sessionsRoot)
        try fm.createDirectory(at: logsRoot, withIntermediateDirectories: true)

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: sessionsRoot,
            logsRoot: logsRoot,
            markerURL: markerURL)

        XCTAssertEqual(report.failures.count, 1)
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        XCTAssertNil(marker["completedMigrationVersion"])
    }

    func testSessionClassificationFailureIsReportedAndCannotBeMarkedComplete() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        let before = try fixture.allMetadataBytes()
        var operations = RecordPrivacyMigrator.FileOperations.live
        let isDirectory = operations.isDirectory
        var classificationCount = 0
        operations.isDirectory = { url in
            if url.standardizedFileURL == fixture.sessionDirectory.standardizedFileURL {
                classificationCount += 1
                throw InjectedFailure.sessionClassification
            }
            return try isDirectory(url)
        }

        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL,
            operations: operations)

        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.untouchedUnknownRecords, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(classificationCount, 1)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
        XCTAssertTrue(try fixture.privacyArtifacts().isEmpty)
        let marker = try fixture.markerObject()
        XCTAssertNil(marker["completedMigrationVersion"])
        XCTAssertEqual(marker["logsClearedMigrationVersion"] as? Int, 1)
    }

    @MainActor
    func testNoticeUsesExactCopyAndOneOKAcknowledgement() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500)
        defer { fixture.remove() }
        _ = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        let first = LaunchNoticeStore(markerURL: fixture.markerURL)
        XCTAssertEqual(
            first.message,
            "Earlier diagnostic logs were cleared so RAWForge no longer retains the phone's "
                + "boot-time clock. Captures and DNG files were not removed.")

        first.acknowledge()

        XCTAssertNil(first.message)
        XCTAssertNil(LaunchNoticeStore(markerURL: fixture.markerURL).message)
        XCTAssertEqual(try fixture.markerObject()["noticeState"] as? String, "acknowledged")
    }

    private func assertWindow(
        _ summary: MotionSummary?,
        _ expectedStart: TimeInterval,
        _ expectedEnd: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(summary?.windowStart ?? -1, expectedStart, accuracy: 0.000_001,
                       file: file, line: line)
        XCTAssertEqual(summary?.windowEnd ?? -1, expectedEnd, accuracy: 0.000_001,
                       file: file, line: line)
    }
}

private enum InjectedFailure: Error {
    case exchange
    case backupCreation
    case backupCleanup
    case markerSave
    case sessionClassification
}

private final class MigrationFixture {
    let root: URL
    let sessionsRoot: URL
    let logsRoot: URL
    let markerURL: URL
    let sessionDirectory: URL
    let sessionURL: URL
    let stationURL: URL
    let motionURL: URL
    let darkURL: URL
    let dngURL: URL

    private let fm = FileManager.default

    private init(root: URL, sessionID: String) throws {
        self.root = root
        sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        logsRoot = root.appendingPathComponent("logs", isDirectory: true)
        markerURL = root.appendingPathComponent("support/privacy-migration-v1.json")
        sessionDirectory = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        sessionURL = sessionDirectory.appendingPathComponent("session.json")
        stationURL = sessionDirectory.appendingPathComponent("station-001.json")
        motionURL = sessionDirectory.appendingPathComponent("motion-001.jsonl")
        darkURL = sessionDirectory.appendingPathComponent("dark-001.json")
        dngURL = sessionDirectory.appendingPathComponent("frame.dng")
        try fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: markerURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
    }

    static func legacyV4(origin: TimeInterval) throws -> MigrationFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordPrivacyMigratorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        let fixture = try MigrationFixture(root: root, sessionID: "legacy-session")
        try fixture.writeLegacySession(origin: origin)
        try fixture.writeLegacyStation()
        try fixture.writeLegacyMotion()
        try fixture.writeLegacyDarkSetting()
        try Data([0x44, 0x4E, 0x47, 0x00, 0xFF]).write(to: fixture.dngURL)
        try Data("legacy uptime 503".utf8).write(
            to: fixture.logsRoot.appendingPathComponent("old-a.log"))
        try Data("legacy uptime 504".utf8).write(
            to: fixture.logsRoot.appendingPathComponent("old-b.log"))
        try Data().write(to: fixture.logsRoot.appendingPathComponent(".running"))
        try Data("keep".utf8).write(to: fixture.logsRoot.appendingPathComponent("notes.txt"))
        let logDirectory = fixture.logsRoot.appendingPathComponent("archive.log", isDirectory: true)
        try fixture.fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: logDirectory.appendingPathComponent("keep.txt"))
        return fixture
    }

    static func unknownSession(schemaVersion: Int) throws -> MigrationFixture {
        let fixture = try legacyV4(origin: 500)
        try fixture.setSessionSchema(schemaVersion)
        try fixture.fm.removeItem(at: fixture.stationURL)
        try fixture.fm.removeItem(at: fixture.motionURL)
        try fixture.fm.removeItem(at: fixture.darkURL)
        return fixture
    }

    func remove() {
        try? fm.removeItem(at: root)
    }

    func currentSession() throws -> SessionRecord {
        try JSONDecoder.rawforgeMigration.decode(SessionRecord.self, from: Data(contentsOf: sessionURL))
    }

    func currentStation() throws -> StationRecord {
        try JSONDecoder.rawforgeMigration.decode(StationRecord.self, from: Data(contentsOf: stationURL))
    }

    func currentDarkSetting() throws -> DarkSettingRecord {
        try JSONDecoder.rawforgeMigration.decode(DarkSettingRecord.self, from: Data(contentsOf: darkURL))
    }

    func currentMotionSamples() throws -> [MotionSample] {
        try Data(contentsOf: motionURL).split(separator: 0x0A).map {
            try JSONDecoder.rawforgeMigration.decode(MotionSample.self, from: Data($0))
        }
    }

    func markerObject() throws -> [String: Any] {
        guard fm.fileExists(atPath: markerURL.path) else { return [:] }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
    }

    func allMetadataBytes() throws -> [String: Data] {
        let urls = try fm.contentsOfDirectory(at: sessionDirectory,
                                             includingPropertiesForKeys: nil)
            .filter {
                ($0.pathExtension == "json" || $0.pathExtension == "jsonl")
                    && !$0.lastPathComponent.contains(".privacy-")
            }
        return try Dictionary(uniqueKeysWithValues: urls.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    func privacyArtifacts() throws -> [String] {
        try fm.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.contains(".privacy-") }
            .sorted()
    }

    func transactionState() throws -> String? {
        let url = sessionDirectory.appendingPathComponent(
            ".privacy-metadata-transaction-v1.json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return object["state"] as? String
    }

    func logPrivacyArtifacts() throws -> [String] {
        try fm.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.contains(".privacy-") }
            .sorted()
    }

    func quarantinedLog(_ name: String) -> URL {
        logsRoot.appendingPathComponent(".privacy-log-cleanup-v1", isDirectory: true)
            .appendingPathComponent(name)
    }

    func corruptStationJSON() throws {
        try Data(#"{"format":"rawforge.station","schemaVersion":2,"broken":true}"#.utf8)
            .write(to: stationURL)
    }

    func corruptDarkJSON() throws {
        try Data(#"{"sensor":"1x","frames":[{"broken":true}]}"#.utf8).write(to: darkURL)
    }

    func setSessionSchema(_ schema: Int) throws {
        try mutateObject(at: sessionURL) { $0["schemaVersion"] = schema }
    }

    func setStationSchema(_ schema: Int) throws {
        try mutateObject(at: stationURL) { $0["schemaVersion"] = schema }
    }

    private func writeLegacySession(origin: TimeInterval) throws {
        let record = SessionRecord(
            sessionId: "legacy-session",
            openedAt: Date(timeIntervalSince1970: 1_000),
            capability: CapabilityReport(device: .current(), sensors: []),
            availableCapacityBytes: 123_456,
            sessionType: "calibration",
            calibrationSessionId: "calibration-parent",
            calibrationAgeSeconds: 42,
            deviceProfile: nil)
        var object = try encodedObject(record)
        object["schemaVersion"] = 4
        object["openedAtUptime"] = origin
        try write(object, to: sessionURL)
    }

    private func writeLegacyStation() throws {
        let frame = makeFrame(
            capture: 503,
            delivery: 503.25,
            latestMotion: 502.75,
            motion: makeSummary(start: 502.8, end: 503),
            neighbourhood: makeSummary(start: 502.5, end: 503.5))
        let station = StationRecord(
            stationIndex: 1,
            sessionId: "legacy-session",
            openedAt: Date(timeIntervalSince1970: 1_001),
            closedAt: Date(timeIntervalSince1970: 1_004),
            brackets: [BracketRecord(
                bracketIndex: 1,
                sensor: "1x",
                sensorUniqueID: "sensor-1",
                captureSet: nil,
                renderedSpecs: nil,
                evOffsetStops: nil,
                executionMode: "sequential",
                bracketRequestSizes: nil,
                droppedRungs: [],
                minimumInterFrameGapSeconds: nil,
                stillnessSettled: true,
                stillnessWaitSeconds: 0.2,
                motionAtFire: makeSummary(start: 502, end: 503),
                dwellSeconds: nil,
                note: nil,
                frames: [frame])],
            captureTimebase: CaptureTimebase(segmentID: "remove-me", originUptime: 500),
            sensorSwaps: [StationRecord.SwapRecord(
                fromSensor: nil,
                toSensor: "1x",
                durationSeconds: 0.4,
                motion: makeSummary(start: 500.5, end: 500.9))],
            motion: makeSummary(start: 501, end: 504),
            motionStreamFile: "motion-001.jsonl",
            motionRequestedHz: 100,
            poseIntent: "tripod",
            estimatedSeconds: 3)
        var object = try encodedObject(station)
        object["schemaVersion"] = 2
        object.removeValue(forKey: "captureSegmentID")
        object.removeValue(forKey: "monotonicTimebase")
        var brackets = try XCTUnwrap(object["brackets"] as? [[String: Any]])
        var frames = try XCTUnwrap(brackets[0]["frames"] as? [[String: Any]])
        makeFrameLegacy(&frames[0])
        brackets[0]["frames"] = frames
        object["brackets"] = brackets
        try write(object, to: stationURL)
    }

    private func writeLegacyDarkSetting() throws {
        let frame = makeFrame(
            capture: 499,
            delivery: nil,
            latestMotion: 501,
            motion: makeSummary(start: 499.5, end: 500.5),
            neighbourhood: nil)
        let setting = DarkSettingRecord(
            sensor: "1x",
            shutterSeconds: 0.01,
            iso: 100,
            requestedRepeats: 1,
            frames: [frame],
            rejections: [],
            aborted: false,
            abortReason: nil)
        var object = try encodedObject(setting)
        var frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        makeFrameLegacy(&frames[0])
        object["frames"] = frames
        try write(object, to: darkURL)
    }

    private func writeLegacyMotion() throws {
        let samples: [[String: Any]] = [
            ["t": 499.9, "gx": 1.0, "gy": 2.0, "gz": 3.0,
             "ax": 4.0, "ay": 5.0, "az": 6.0],
            ["t": 502.9, "gx": 1.1, "gy": 2.1, "gz": 3.1,
             "ax": 4.1, "ay": 5.1, "az": 6.1],
            ["t": 503.1, "gx": 1.2, "gy": 2.2, "gz": 3.2,
             "ax": 4.2, "ay": 5.2, "az": 6.2],
        ]
        var data = Data()
        for sample in samples {
            data.append(try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: motionURL)
    }

    private func makeFrame(
        capture: TimeInterval,
        delivery: TimeInterval?,
        latestMotion: TimeInterval?,
        motion: MotionSummary?,
        neighbourhood: MotionSummary?
    ) -> FrameRecord {
        FrameRecord(
            frameIndex: 1,
            filename: dngURL.lastPathComponent,
            sensor: "1x",
            requested: FrameRecord.Exposure(
                shutterSeconds: 0.01, iso: 100, whiteBalanceGains: nil),
            deviceAchieved: nil,
            photoAchieved: nil,
            dng: FrameRecord.DNGWitness(
                exposureTimeSeconds: 0.01,
                iso: 100,
                asShotNeutral: nil,
                blackLevel: nil,
                whiteLevel: nil,
                cfaPattern: nil,
                activeArea: nil,
                uniqueCameraModel: "fixture",
                localizedCameraModel: nil,
                noiseReductionAppliedCoerced: nil,
                noiseReductionApplied: nil,
                noiseProfile: nil,
                dateTimeOriginal: nil,
                subsecTimeOriginal: nil,
                storedImageWidth: nil,
                imageWidth: nil,
                imageHeight: nil),
            focus: nil,
            zoomFactor: 1,
            capturedAtSegmentStartSeconds: capture,
            capturedAt: Date(timeIntervalSince1970: 1_003),
            photoTimestampSeconds: 700,
            gapFromPreviousSeconds: nil,
            clipping: nil,
            motion: motion,
            motionNeighbourhood: neighbourhood,
            deliveredAtSegmentStartSeconds: delivery,
            latestMotionAtSegmentStartSeconds: latestMotion)
    }

    private func makeFrameLegacy(_ frame: inout [String: Any]) {
        frame["capturedAtUptime"] = frame.removeValue(forKey: "capturedAtSegmentStartSeconds")
        if let value = frame.removeValue(forKey: "deliveredAtSegmentStartSeconds") {
            frame["uptimeAtDelivery"] = value
        }
        if let value = frame.removeValue(forKey: "latestMotionAtSegmentStartSeconds") {
            frame["latestMotionTimestamp"] = value
        }
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.rawforgeMigration.encode(value))
                as? [String: Any])
    }

    private func mutateObject(at url: URL, _ mutation: (inout [String: Any]) -> Void) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        mutation(&object)
        try write(object, to: url)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url)
    }
}

private func makeSummary(start: TimeInterval, end: TimeInterval) -> MotionSummary {
    MotionSummary(
        windowStart: start,
        windowEnd: end,
        sampleCount: 2,
        effectiveHz: 100,
        worstGapSeconds: 0.01,
        gyroP50: 0.1,
        gyroP90: 0.2,
        gyroP99: 0.3,
        gyroMax: 0.4,
        accelP50: 0.5,
        accelP90: 0.6,
        accelP99: 0.7,
        accelMax: 0.8)
}

private extension JSONEncoder {
    static var rawforgeMigration: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var rawforgeMigration: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
