import XCTest
@testable import RAWForge

final class RecipeSnapshotRecordTests: XCTestCase {
    func testTakeKeepsCompleteDefinitionWhenLibraryDraftChanges() throws {
        var recipe = recipeFixture(steps: [try .validated(sensor: .wide, captureSet: recipeSet(count: 16))])
        let snapshot = RecipeSnapshot(recipe)
        let correlation = UUID()
        let record = StationRecord(stationIndex: 1, sessionId: "RUN", openedAt: Date(timeIntervalSince1970: 10),
            closedAt: Date(timeIntervalSince1970: 11), brackets: [],
            captureTimebase: .init(segmentID: "segment", originUptime: 1),
            recipeSnapshot: snapshot, correlationID: correlation)
        recipe.steps[0].captureSet.executionMode = .sequential
        let decoded = try JSONDecoder().decode(StationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.recipeSnapshot, snapshot)
        XCTAssertEqual(decoded.recipeSnapshot?.capturedDefinition.steps[0].captureSet.firing, .hardwareBracket)
        XCTAssertEqual(decoded.correlationID, correlation)
    }

    func testPrivacySafeV4TakeRemainsReadableWithoutInventingRecipeIdentity() throws {
        let record = StationRecord(stationIndex: 1, sessionId: "RUN", openedAt: Date(timeIntervalSince1970: 10),
            closedAt: Date(timeIntervalSince1970: 11), brackets: [],
            captureTimebase: .init(segmentID: "segment", originUptime: 1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["schemaVersion"] = 4
        let decoded = try JSONDecoder().decode(StationRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.recipeSnapshot)
        XCTAssertNil(decoded.correlationID)
        XCTAssertEqual(decoded.captureSegmentID, "segment")
    }
}
