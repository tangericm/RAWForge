import XCTest
@testable import RAWForge

final class ActiveRunStoreTests: XCTestCase {
    private var root: URL!
    private var store: ActiveRunStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ActiveRunStore(url: root.appendingPathComponent("active-run.json"))
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testRecoveryDerivesNextIndexFromHighestBankedTakeNotCount() throws {
        try store.activate(sessionID: "RUN")
        let result = try store.recover(loadSession: { _ in self.header() },
            loadStations: { _ in ([self.take(2), self.take(7)], []) })
        XCTAssertEqual(result.run?.sessionID, "RUN")
        XCTAssertEqual(result.run?.nextTakeIndex, 8)
        XCTAssertNil(result.warning)
        let pointer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("active-run.json"))) as? [String: Any])
        XCTAssertEqual(Set(pointer.keys), ["sessionID", "schemaVersion"])
    }

    func testMissingOrMismatchedHeaderClearsOnlyBookmark() throws {
        for header in [nil, self.header(id: "OTHER"), self.header(type: "calibration")] {
            try store.activate(sessionID: "RUN")
            let recovered = try store.recover(loadSession: { _ in header },
                loadStations: { _ in XCTFail("invalid header must stop recovery"); return ([], []) })
            XCTAssertNil(recovered.run)
            XCTAssertNotNil(recovered.warning)
            XCTAssertNil(try store.pointer())
        }
    }

    func testUnreadableMismatchedOrDuplicateTakesBlockResume() throws {
        for listing in [([take(1)], ["station-002.json"]),
                        ([take(1), take(1)], []), ([take(1, session: "OTHER")], []),
                        ([take(0)], []), ([take(Int.max)], [])] {
            try store.activate(sessionID: "RUN")
            let result = try store.recover(loadSession: { _ in self.header() }, loadStations: { _ in listing })
            XCTAssertNil(result.run)
            XCTAssertNotNil(result.warning)
            XCTAssertNil(try store.pointer())
        }
    }

    func testMalformedBookmarkNeverReachesFilesystemLookup() throws {
        for id in ["../outside", "/private", ".", "", "a/b"] {
            XCTAssertThrowsError(try store.activate(sessionID: id))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"sessionID":"../outside"}"#.utf8)
            .write(to: root.appendingPathComponent("active-run.json"))
        let result = try store.recover(loadSession: { _ in XCTFail("unsafe ID"); return nil },
            loadStations: { _ in XCTFail("unsafe ID"); return ([], []) })
        XCTAssertNil(result.run)
        XCTAssertNotNil(result.warning)
    }

    func testFinishForgetsRunWithoutDeletingItsRecords() throws {
        let headerURL = root.appendingPathComponent("RUN/session.json")
        try RecipeFile.write(header(), to: headerURL)
        let before = try Data(contentsOf: headerURL)
        try store.activate(sessionID: "RUN")
        try store.finish()
        XCTAssertNil(try store.pointer())
        XCTAssertEqual(try Data(contentsOf: headerURL), before)
        XCTAssertNil(try store.recover(loadSession: { _ in XCTFail(); return nil }, loadStations: { _ in ([], []) }).run)
    }

    func testMissingDirectoryDoesNotMasqueradeAsAnEmptyRun() {
        let listing = SessionStore.loadStationsDetailed("missing-\(UUID().uuidString)")
        XCTAssertFalse(listing.unreadable.isEmpty)
    }

    func testMetadataUpdatesSidecarWithoutChangingHeader() throws {
        let headerURL = root.appendingPathComponent("RUN/session.json")
        try RecipeFile.write(header(), to: headerURL)
        let bytes = try Data(contentsOf: headerURL)
        let metadata = RunMetadataStore(root: root)
        try metadata.save(.init(name: "Studio", note: "Reflectance"), sessionID: "RUN")
        try metadata.save(.init(name: "Kitchen", note: nil), sessionID: "RUN")
        XCTAssertEqual(try metadata.load(sessionID: "RUN")?.name, "Kitchen")
        XCTAssertEqual(try Data(contentsOf: headerURL), bytes)
        XCTAssertThrowsError(try metadata.save(.init(name: "Invalid", note: nil), sessionID: "../outside"))
    }

    private func header(id: String = "RUN", type: String = "scene") -> SessionRecord {
        SessionRecord(sessionId: id, openedAt: Date(timeIntervalSince1970: 10),
                      capability: recipeStorageReport(), availableCapacityBytes: 1_000_000, sessionType: type)
    }
    private func take(_ index: Int, session: String = "RUN") -> StationRecord {
        StationRecord(stationIndex: index, sessionId: session, openedAt: Date(timeIntervalSince1970: 10),
            closedAt: Date(timeIntervalSince1970: 11), brackets: [],
            captureTimebase: CaptureTimebase(segmentID: "old", originUptime: 1))
    }
}
