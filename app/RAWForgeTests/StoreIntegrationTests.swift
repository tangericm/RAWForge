import XCTest
@testable import RAWForge

/// These touch the real filesystem in the simulator's container. They exercise
/// the paths where a bug loses data rather than merely displaying it wrong.
final class StoreIntegrationTests: XCTestCase {

    private enum InjectedBackupError: Error {
        case setterFailed
    }

    private enum InjectedRemovalError: Error {
        case refused
    }

    private var created: [String] = []
    private var createdProtocols: [String] = []

    override func tearDown() {
        for id in created { try? SessionStore.deleteSession(id) }
        for name in createdProtocols { ProtocolLibrary.delete(named: name) }
        created = []
        createdProtocols = []
        ShotListStore.clear()
        super.tearDown()
    }

    private func makeSession(_ suffix: String) throws -> String {
        let id = "TEST\(suffix)"
        let directory = SessionStore.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = SessionRecord(
            sessionId: id,
            openedAt: Date(timeIntervalSince1970: 1_000),
            capability: CapabilityReport(device: .current(), sensors: []),
            availableCapacityBytes: 1_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(
            to: directory.appendingPathComponent("session.json"))
        created.append(id)
        return id
    }

    private func writeFrame(_ session: String, station: Int, frame: Int) throws {
        let name = SessionStore.frameFilename(
            sessionId: session, station: station, bracket: 1, frame: frame, sensor: "1x")
        _ = try SessionStore.writeFrame(Data(repeating: 0xAB, count: 64),
                                        named: name, sessionId: session)
    }

    private func writeStation(_ session: String, index: Int) throws {
        try SessionStore.writeStation(StationRecord(
            stationIndex: index, sessionId: session, openedAt: Date(), closedAt: Date(),
            brackets: [],
            captureTimebase: CaptureTimebase(segmentID: "test-segment", originUptime: 0),
            sensorSwaps: []))
    }

    private func writeMotion(_ session: String, station: Int) throws {
        let name = String(format: "motion-%03d.jsonl", station)
        try Data("{}\n".utf8).write(
            to: SessionStore.directory(for: session).appendingPathComponent(name))
    }

    // MARK: - Filenames

    func testFrameFilenameIsZeroPaddedAndSelfDescribing() {
        let name = SessionStore.frameFilename(
            sessionId: "20260808T142211Z", station: 1, bracket: 3, frame: 2, sensor: "1x")
        XCTAssertEqual(name, "20260808T142211Z_s001_b03_f02_1x.dng")
    }

    func testDarkFrameFilenameDoesNotBorrowStationNaming() {
        let name = SessionStore.darkFrameFilename(
            sessionId: "S", setting: 7, repeatIndex: 3, sensor: "tele")
        XCTAssertEqual(name, "S_d007_r03_tele.dng")
        XCTAssertFalse(name.contains("_s"), "a dark frame has no station")
    }

    // MARK: - Backup exclusion

    func testOpenRefusesToCreateSessionWhenBackupExclusionSetterThrows() {
        let now = Date(timeIntervalSince1970: 4_102_444_800)
        let id = SessionStore.makeSessionId(now)
        created.append(id)

        XCTAssertThrowsError(try SessionStore.open(
            capability: CapabilityReport(device: .current(), sensors: []),
            now: now,
            backupExclusion: .init { _ in throw InjectedBackupError.setterFailed }
        )) { error in
            guard case SessionStore.StoreError.cannotExcludeFromBackup = error else {
                return XCTFail("expected typed backup-exclusion failure, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SessionStore.directory(for: id).path),
            "a privacy-setting failure must happen before session data exists")
    }

    func testOpenRefusesToCreateSessionWhenBackupExclusionReadbackIsFalse() {
        let now = Date(timeIntervalSince1970: 4_102_444_801)
        let id = SessionStore.makeSessionId(now)
        created.append(id)

        XCTAssertThrowsError(try SessionStore.open(
            capability: CapabilityReport(device: .current(), sensors: []),
            now: now,
            backupExclusion: .init { _ in false }
        )) { error in
            guard case SessionStore.StoreError.cannotExcludeFromBackup = error else {
                return XCTFail("expected typed backup-exclusion failure, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SessionStore.directory(for: id).path),
            "an unverifiable privacy setting must happen before session data exists")
    }

    func testOpenUsesRealBackupExclusionAndVerifiesItOnTheSessionsRoot() throws {
        let now = Date(timeIntervalSince1970: 4_102_444_802)
        let id = SessionStore.makeSessionId(now)
        created.append(id)

        _ = try SessionStore.open(
            capability: CapabilityReport(device: .current(), sensors: []),
            now: now)

        let values = try SessionStore.sessionsRoot.resourceValues(
            forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            SessionStore.directory(for: id)
                .appendingPathComponent("session.json").path))
    }

    // MARK: - The orphan sweep

    /// A phone death mid-station must leave nothing: a frame whose station has
    /// no record belongs to a station that never existed.
    func testSweepRemovesFramesOfAnUnclosedStation() throws {
        let id = try makeSession("Orphan")
        try writeFrame(id, station: 1, frame: 1)
        try writeFrame(id, station: 1, frame: 2)
        try writeMotion(id, station: 1)
        XCTAssertEqual(SessionStore.frameAndStationCount(sessionId: id).frames, 2)

        SessionStore.sweepOrphanedFrames()

        let files = try FileManager.default.contentsOfDirectory(
            at: SessionStore.directory(for: id), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.filter { $0.pathExtension == "dng" }.isEmpty,
                      "frames of a station that never closed must not survive")
        XCTAssertFalse(files.contains { $0.lastPathComponent == "motion-001.jsonl" },
                       "motion from a station that never closed must not survive")
    }

    /// And a station that did close must be untouched — the sweep is not a
    /// blunt instrument.
    func testSweepPreservesFramesOfAClosedStation() throws {
        let id = try makeSession("Closed")
        try writeFrame(id, station: 1, frame: 1)
        try writeMotion(id, station: 1)
        try writeStation(id, index: 1)

        SessionStore.sweepOrphanedFrames()

        let files = try FileManager.default.contentsOfDirectory(
            at: SessionStore.directory(for: id), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "dng" }.count, 1)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "motion-001.jsonl" })
    }

    /// The mixed case is the one that matters: banked stations survive while
    /// the in-flight one goes.
    func testSweepIsSelectiveWithinOneSession() throws {
        let id = try makeSession("Mixed")
        try writeFrame(id, station: 1, frame: 1)
        try writeStation(id, index: 1)
        try writeFrame(id, station: 2, frame: 1)

        SessionStore.sweepOrphanedFrames()

        let names = try FileManager.default.contentsOfDirectory(
            at: SessionStore.directory(for: id), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter { $0.hasSuffix(".dng") }
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].contains("_s001_"))
    }

    func testSweepDoesNotReportAFrameAsRemovedWhenDeletionFails() throws {
        let id = try makeSession("RemovalFailure")
        try writeFrame(id, station: 1, frame: 1)
        let frameURL = SessionStore.directory(for: id).appendingPathComponent(
            SessionStore.frameFilename(
                sessionId: id, station: 1, bracket: 1, frame: 1, sensor: "1x"))
        let bytes = try Data(contentsOf: frameURL)

        let removed = SessionStore.sweepOrphanedFrames { url in
            if url.standardizedFileURL == frameURL.standardizedFileURL {
                throw InjectedRemovalError.refused
            }
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertEqual(removed, 0, "the launch notice may count only successful deletion")
        XCTAssertEqual(try Data(contentsOf: frameURL), bytes)
    }

    // MARK: - Unreadable records

    /// A station file that does not parse must be reported, not silently
    /// dropped — the browser showing four of five with no explanation is worse
    /// than an error.
    func testCorruptStationFileIsReportedRatherThanHidden() throws {
        let id = try makeSession("Corrupt")
        try writeStation(id, index: 1)
        try Data("{ not json".utf8).write(
            to: SessionStore.directory(for: id).appendingPathComponent("station-002.json"))

        let loaded = SessionStore.loadStationsDetailed(id)
        XCTAssertEqual(loaded.stations.count, 1)
        XCTAssertEqual(loaded.unreadable, ["station-002.json"])
    }

    // MARK: - Shot list persistence

    func testShotListRoundTripsButTheCursorDoesNot() {
        let entry = ShotListEntry(
            index: 0, sensor: .telephoto,
            captureSet: .repeated(CaptureSpec(shutterSeconds: 0.02, iso: 200), count: 4, name: "p"))
        ShotListStore.save(ShotList(entries: [entry], cursor: 1), grouped: false)

        let restored = ShotListStore.load()
        XCTAssertEqual(restored?.entries.count, 1)
        XCTAssertEqual(restored?.entries[0].sensor, .telephoto)
        XCTAssertEqual(restored?.entries[0].captureSet.specs.count, 4)
        XCTAssertEqual(restored?.groupedBySensor, false)
        // The cursor is deliberately absent: restoring a half-walked cursor
        // would restore a station that never existed.
        XCTAssertFalse("\(restored!)".contains("cursor"))
    }

    func testClearRemovesThePersistedList() {
        ShotListStore.save(ShotList(entries: [], cursor: 0), grouped: true)
        ShotListStore.clear()
        XCTAssertNil(ShotListStore.load())
    }

    // MARK: - Protocol persistence

    func testProtocolLibraryPreservesSequentialFiringMode() throws {
        let name = "TEST-sequential-\(UUID().uuidString)"
        createdProtocols.append(name)
        var captureSet = CaptureSet.repeated(
            CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
            count: 16,
            name: name)
        captureSet.executionMode = .sequential

        _ = try ProtocolLibrary.save(captureSet, as: name)

        XCTAssertEqual(
            ProtocolLibrary.load(named: name)?.firing,
            .sequential,
            "saving through the protocol library must preserve how the frames fire")
    }

    // MARK: - Export

    func testArchiveProducesAZipContainingTheSession() throws {
        let id = try makeSession("Export")
        try writeFrame(id, station: 1, frame: 1)
        try writeStation(id, index: 1)

        let url = try SessionExport.archive(sessionId: id)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        XCTAssertGreaterThan(size, 100, "an empty archive means nothing was packaged")

        // The source must be untouched by exporting it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionStore.directory(for: id).path))
    }

    func testArchivingAMissingSessionThrowsRatherThanReturningAnEmptyZip() {
        XCTAssertThrowsError(try SessionExport.archive(sessionId: "DoesNotExist"))
    }
}
