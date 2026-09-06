import XCTest
@testable import RAWForge

final class OrphanOwnershipSafetyTests: XCTestCase {
    func testMismatchedHeaderPreservesFrameAndMotionBytes() throws {
        for headerID in ["OTHER_RUN", ""] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RAWForge-Ownership-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let runID = "FIXTURE_RUN"
            let directory = root.appendingPathComponent(runID, isDirectory: true)
            let headerURL = directory.appendingPathComponent("session.json")
            let header = SessionRecord(sessionId: headerID, openedAt: Date(timeIntervalSince1970: 500),
                capability: recipeStorageReport(), availableCapacityBytes: 1_000_000,
                deviceProfile: nil)
            try RecipeFile.write(header, to: headerURL)
            let headerBytes = try Data(contentsOf: headerURL)
            let frame = directory.appendingPathComponent(SessionStore.frameFilename(
                sessionId: runID, station: 1, bracket: 1, frame: 1, sensor: "1x"))
            let motion = directory.appendingPathComponent("motion-001.jsonl")
            let frameBytes = Data(repeating: 0xAB, count: 64)
            let motionBytes = Data("{\"timestamp\":1}\n".utf8)
            try frameBytes.write(to: frame, options: .withoutOverwriting)
            try motionBytes.write(to: motion, options: .withoutOverwriting)

            XCTAssertTrue(SessionStore.orphanCleanupCandidates(sessionsRoot: root).isEmpty)
            let removed = SessionStore.sweepOrphanedFrames(sessionsRoot: root, removeItem: { url in
                XCTFail("Inconsistent ownership must not authorize removal: \(url.lastPathComponent)")
            })
            XCTAssertEqual(removed, 0)
            XCTAssertEqual(try Data(contentsOf: frame), frameBytes)
            XCTAssertEqual(try Data(contentsOf: motion), motionBytes)
            XCTAssertEqual(try Data(contentsOf: headerURL), headerBytes)
        }
    }
}
