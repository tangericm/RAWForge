import XCTest
@testable import RAWForge

final class DebugLogPrivacyTests: XCTestCase {
    func testExportedLineStartsAtLaunchRelativeTimeAndOmitsWallClock() throws {
        let clock = TestUptimeClock(now: 987_654)
        let log = DebugLog(uptime: { clock.now })
        let message = "privacy-test-\(UUID().uuidString)"

        // The app under test opens its own second-resolution launch log. Cross
        // a timestamp boundary so this private recorder cannot share that file.
        Thread.sleep(forTimeInterval: 1.05)
        clock.now = 1_000_000
        log.start(device: deviceIdentity())
        defer {
            if let fileURL = log.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

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

private final class TestUptimeClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}
