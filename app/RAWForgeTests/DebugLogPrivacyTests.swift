import XCTest
@testable import RAWForge

final class DebugLogPrivacyTests: XCTestCase {
    func testFormattedLineUsesLaunchRelativeTimeAndOmitsRawUptime() throws {
        let rawUptime = 987_654.0
        let log = DebugLog(uptime: { rawUptime })

        log.write(.info, .app, "privacy test")

        let line = try XCTUnwrap(log.snapshot().last?.line)
        XCTAssertTrue(line.contains("+0."))
        XCTAssertFalse(line.contains("987654.0"))
    }
}
