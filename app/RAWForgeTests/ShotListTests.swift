import XCTest
@testable import RAWForge

final class ShotListTests: XCTestCase {

    private func entry(_ i: Int, _ s: SensorCapability.Sensor, _ name: String = "p") -> ShotListEntry {
        ShotListEntry(index: i, sensor: s,
                      captureSet: .repeated(CaptureSpec(shutterSeconds: 0.01, iso: 100),
                                            count: 3, name: name))
    }

    /// #8: group-by-sensor is the default, and grouping must not lose entries
    /// or reorder within a sensor.
    func testGroupingKeepsEveryEntryAndPreservesWithinSensorOrder() {
        let input = [entry(0, .wide, "a"), entry(1, .telephoto, "b"),
                     entry(2, .wide, "c"), entry(3, .ultraWide, "d")]
        let grouped = ShotList.grouped(input)
        XCTAssertEqual(grouped.count, 4)
        XCTAssertEqual(grouped.map(\.sensor), [.wide, .wide, .telephoto, .ultraWide])
        XCTAssertEqual(grouped[0].captureSet.name, "a")
        XCTAssertEqual(grouped[1].captureSet.name, "c")
    }

    func testGroupingReindexesContiguously() {
        let grouped = ShotList.grouped([entry(0, .telephoto), entry(1, .wide), entry(2, .telephoto)])
        XCTAssertEqual(grouped.map(\.index), [0, 1, 2])
    }

    /// A station completes or never existed: closing is only legal once the
    /// cursor has passed the end.
    func testCannotCloseUntilTheShotListIsWalked() {
        var list = ShotList(entries: [entry(0, .wide), entry(1, .wide)], cursor: 0)
        XCTAssertFalse(list.canClose)
        list.cursor = 1
        XCTAssertFalse(list.canClose)
        list.cursor = 2
        XCTAssertTrue(list.canClose)
    }

    func testEmptyShotListCannotClose() {
        XCTAssertFalse(ShotList(entries: [], cursor: 0).canClose)
    }

    func testTotalFramesSumsEveryEntry() {
        let list = ShotList(entries: [entry(0, .wide), entry(1, .telephoto)], cursor: 0)
        XCTAssertEqual(list.totalFrames, 6)
    }
}
