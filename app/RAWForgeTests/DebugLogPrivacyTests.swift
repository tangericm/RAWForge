import XCTest
@testable import RAWForge

final class DebugLogPrivacyTests: XCTestCase {
    func testExportedLineStartsAtLaunchRelativeTimeAndOmitsWallClock() throws {
        let clock = TestUptimeClock(now: 987_654)
        let storageDirectory = try makeTemporaryDirectory()
        let log = DebugLog(storageDirectory: storageDirectory, uptime: { clock.now })
        let message = "privacy-test-\(UUID().uuidString)"

        clock.now = 1_000_000
        log.start(device: deviceIdentity())
        defer { log.noteCleanExit() }

        clock.now = 1_000_012.345
        log.write(.info, .app, message)
        log.flush()

        let entry = try XCTUnwrap(log.snapshot().last)
        XCTAssertEqual(entry.elapsedSinceLaunch, 12.345, accuracy: 0.000_001,
                       "start(device:) must establish a fresh launch origin")
        XCTAssertTrue(entry.line.hasPrefix("\(entry.clock) +12.345s"),
                      "the in-memory display retains its wall clock")

        let fileURL = try XCTUnwrap(log.fileURL)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let exportedLine = try XCTUnwrap(
            contents.split(separator: "\n").map(String.init).first { $0.contains(message) })
        XCTAssertTrue(exportedLine.hasPrefix("+12.345s "),
                      "the exported line must begin with launch-relative time")
        XCTAssertFalse(exportedLine.contains(entry.clock),
                       "the exported diagnostic must not contain a wall-clock column")
    }

    func testDiagnosticStorageExcludesRetainedLogsFromBackupAndProvidesAReportURL() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let retainedLog = storageDirectory.appendingPathComponent("retained.log")
        let retainedContents = Data("retained diagnostic".utf8)
        try retainedContents.write(to: retainedLog)
        let log = DebugLog(storageDirectory: storageDirectory)

        log.start(device: deviceIdentity())
        defer { log.noteCleanExit() }

        let values = try storageDirectory.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(try Data(contentsOf: retainedLog), retainedContents,
                       "excluding diagnostics from backup must not replace retained logs")

        let reportURL = try XCTUnwrap(log.currentReportURL())
        XCTAssertEqual(
            reportURL.deletingLastPathComponent().standardizedFileURL,
            storageDirectory.standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
    }

    func testBackupExclusionFailureKeepsDiagnosticsInMemoryAndCreatesNoReport() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let log = DebugLog(
            storageDirectory: storageDirectory,
            backupExclusion: { _ in throw ForcedStorageError.backupExclusion }
        )

        log.start(device: deviceIdentity())
        defer { log.noteCleanExit() }
        log.write(.warn, .app, "in-memory witness")
        log.flush()

        XCTAssertNil(log.fileURL)
        XCTAssertNil(log.currentReportURL())
        XCTAssertTrue(log.snapshot().contains { $0.message == "in-memory witness" })

        let storedItems = try FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(storedItems.contains { $0.pathExtension == "log" })
        XCTAssertFalse(storedItems.contains { $0.lastPathComponent == ".running" })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawforge-debug-log-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func deviceIdentity() -> DeviceIdentity {
        DeviceIdentity(
            modelIdentifier: "iPhone16,1",
            systemName: "iOS",
            systemVersion: "17.0",
            appVersion: "1.0",
            appBuild: "1",
            appCommit: "test",
            isSimulator: true)
    }
}

private enum ForcedStorageError: Error {
    case backupExclusion
}

private final class TestUptimeClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}
