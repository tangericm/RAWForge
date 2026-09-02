import XCTest
@testable import RAWForge

/// Which directory a file belongs in, and getting existing installs there.
///
/// `UIFileSharingEnabled` shares the whole of `Documents` to the Files app.
/// That is wanted for sessions, logs and protocols and unwanted for the app's
/// own bookkeeping, so the split is load-bearing rather than tidiness — and the
/// migration is the part with actual risk in it, since an install that predates
/// the change already has those files in the old place.
final class AppStorageTests: XCTestCase {

    private let fm = FileManager.default

    private func cleanUp() {
        for name in AppStorage.filesMovedOutOfDocuments {
            try? fm.removeItem(at: AppStorage.documentsDirectory.appendingPathComponent(name))
            try? fm.removeItem(at: AppStorage.supportFile(name))
        }
    }

    override func setUp() { super.setUp(); cleanUp() }
    override func tearDown() { cleanUp(); super.tearDown() }

    // MARK: - The split

    func testAppStateLivesOutsideTheDirectoryThatIsSharedToFiles() {
        let documents = AppStorage.documentsDirectory.path
        XCTAssertFalse(DeviceProfile.fileURL.path.hasPrefix(documents),
                       "the device profile is app state and must not be browsable in Files")
        XCTAssertTrue(DeviceProfile.fileURL.path.contains("Application Support"))
    }

    /// The counterpart: what the user *would* recognise as theirs stays put,
    /// because Files is how it leaves the phone.
    func testTheUsersOwnDataStaysInDocuments() {
        let documents = AppStorage.documentsDirectory.path
        XCTAssertTrue(SessionStore.sessionsRoot.path.hasPrefix(documents),
                      "sessions are the point of the app and must remain shareable")
        XCTAssertTrue(ProtocolLibrary.directory.path.hasPrefix(documents),
                      "protocols are authored by the user")
        XCTAssertTrue(DebugLog.directory.path.hasPrefix(documents),
                      "logs are deliberately handed over when something goes wrong")
        XCTAssertTrue(DebugLog.legacyDirectory.path.hasPrefix(documents),
                      "legacy reports stay available only to the privacy migrator")
        XCTAssertNotEqual(DebugLog.directory, DebugLog.legacyDirectory,
                          "safe reports must not share an enumeration root with legacy logs")
    }

    // MARK: - Migration

    func testAFileLeftInDocumentsIsMovedRatherThanAbandoned() throws {
        let name = "shot-list.json"
        let old = AppStorage.documentsDirectory.appendingPathComponent(name)
        try Data("{\"marker\":1}".utf8).write(to: old)

        XCTAssertTrue(AppStorage.migrateFromDocuments(name))

        XCTAssertFalse(fm.fileExists(atPath: old.path), "the old copy should be gone")
        let moved = try Data(contentsOf: AppStorage.supportFile(name))
        XCTAssertEqual(String(decoding: moved, as: UTF8.self), "{\"marker\":1}",
                       "the contents must survive — this is somebody's authored shot list")
    }

    func testMigrationIsSilentWhenThereIsNothingToMove() {
        XCTAssertFalse(AppStorage.migrateFromDocuments("shot-list.json"))
        XCTAssertFalse(fm.fileExists(atPath: AppStorage.supportFile("shot-list.json").path),
                       "nothing should be conjured into the new location")
    }

    /// Both present means the old one is a leftover, not a second opinion —
    /// otherwise a stale file could overwrite current state on a later launch.
    func testWhenBothExistTheNewLocationWinsAndTheStaleCopyIsRemoved() throws {
        let name = "device-profile.json"
        let old = AppStorage.documentsDirectory.appendingPathComponent(name)
        try Data("stale".utf8).write(to: old)
        try Data("current".utf8).write(to: AppStorage.supportFile(name))

        XCTAssertFalse(AppStorage.migrateFromDocuments(name), "nothing was moved")

        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: AppStorage.supportFile(name)), as: UTF8.self),
                       "current", "the newer location must not be overwritten by a leftover")
    }

    func testRunningTheMigrationTwiceChangesNothingTheSecondTime() throws {
        let name = "shot-list.json"
        try Data("once".utf8).write(to: AppStorage.documentsDirectory.appendingPathComponent(name))

        AppStorage.migrateAll()
        let afterFirst = try Data(contentsOf: AppStorage.supportFile(name))
        AppStorage.migrateAll()
        let afterSecond = try Data(contentsOf: AppStorage.supportFile(name))

        XCTAssertEqual(afterFirst, afterSecond)
    }

    /// The store reads through the same path the migration writes to, so a
    /// shot list authored before the split is still there afterwards.
    func testAShotListSurvivesTheMoveAndIsStillReadable() throws {
        let entry = ShotListEntry(
            index: 0, sensor: .wide,
            captureSet: .repeated(CaptureSpec(shutterSeconds: 0.004, iso: 100),
                                  count: 4, name: "survives"))
        ShotListStore.save(ShotList(entries: [entry], cursor: 0), grouped: true)

        // Simulate the pre-split layout by putting it back where it used to be.
        let name = "shot-list.json"
        let stored = try Data(contentsOf: AppStorage.supportFile(name))
        try fm.removeItem(at: AppStorage.supportFile(name))
        try stored.write(to: AppStorage.documentsDirectory.appendingPathComponent(name))

        AppStorage.migrateAll()

        let restored = try XCTUnwrap(ShotListStore.load(), "the shot list did not survive the move")
        XCTAssertEqual(restored.entries.first?.captureSet.name, "survives")
        XCTAssertTrue(restored.groupedBySensor)
    }
}
