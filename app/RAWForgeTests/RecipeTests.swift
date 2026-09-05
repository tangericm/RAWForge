import XCTest
@testable import RAWForge

final class RecipeTests: XCTestCase {
    func testRenderingPreservesOrderFiringAndTimingBeyondBracketCeiling() throws {
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .wide, captureSet: recipeSet(count: 16), dwellSeconds: 0),
            try .validated(sensor: .telephoto, captureSet: recipeSet(firing: .sequential),
                           dwellSeconds: 0.2, sequentialGapSeconds: 0.5),
            try .validated(sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0.3)
        ])
        let entries = recipe.renderedEntries()
        XCTAssertEqual(entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(entries.map(\.sensor), [.wide, .telephoto, .wide])
        XCTAssertEqual(entries.map { $0.captureSet.firing }, [.hardwareBracket, .sequential, .hardwareBracket])
        XCTAssertEqual(entries.map(\.frameCount), [16, 1, 1])
        XCTAssertEqual(entries.map(\.dwellSeconds), [0, 0.2, 0.3])
        XCTAssertEqual(entries.map(\.minimumGapSeconds), [nil, 0.5, nil])
        XCTAssertEqual(entries.map(\.captureSet), recipe.steps.map(\.captureSet))
    }

    func testValidatedFactoryRejectsInvalidTimingAndEmptySets() {
        for dwell in [-1, Double.nan, .infinity] {
            XCTAssertThrowsError(try RecipeStep.validated(
                sensor: .wide, captureSet: recipeSet(), dwellSeconds: dwell))
        }
        for gap in [-1, Double.nan, .infinity] {
            XCTAssertThrowsError(try RecipeStep.validated(
                sensor: .wide, captureSet: recipeSet(firing: .sequential),
                dwellSeconds: 0, sequentialGapSeconds: gap))
        }
        XCTAssertThrowsError(try RecipeStep.validated(
            sensor: .wide, captureSet: recipeSet(specs: []), dwellSeconds: 0))
    }

    func testBurstRejectsEvenAZeroGapAndLegacyFiringIsStoredExplicitly() throws {
        for gap in [0, 0.25] {
            XCTAssertThrowsError(try RecipeStep.validated(
                sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0, sequentialGapSeconds: gap))
        }
        var legacy = recipeSet()
        legacy.executionMode = nil
        let step = try RecipeStep.validated(sensor: .wide, captureSet: legacy, dwellSeconds: 0)
        XCTAssertEqual(step.captureSet.executionMode, .hardwareBracket)
        XCTAssertNoThrow(try RecipeStep.validated(sensor: .wide,
            captureSet: recipeSet(firing: .sequential), dwellSeconds: 0, sequentialGapSeconds: 0))
    }

    func testSnapshotAndCodablePreserveTheCompleteDefinitionDespiteDraftEdits() throws {
        var recipe = recipeFixture(steps: [try .validated(sensor: .telephoto,
            captureSet: recipeSet(firing: .sequential), dwellSeconds: 0.2, sequentialGapSeconds: 0.5)])
        let original = recipe
        let snapshot = RecipeSnapshot(recipe)
        recipe.name = "Edited"
        recipe.steps[0].captureSet.executionMode = .hardwareBracket
        recipe.steps[0].dwellSeconds = 7
        recipe.note = "changed"
        XCTAssertEqual(snapshot.recipeID, original.id)
        XCTAssertEqual(snapshot.name, "Original")
        XCTAssertEqual(snapshot.version, 3)
        XCTAssertEqual(snapshot.capturedDefinition, original)
        XCTAssertEqual(try JSONDecoder().decode(RecipeSnapshot.self,
            from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(try JSONDecoder().decode(Recipe.self,
            from: JSONEncoder().encode(original)), original)
    }

    func testLegacyShotListEntryDecodesWithoutNewTimingOrFiringKeys() throws {
        let json = #"{"index":2,"sensor":"1x","captureSet":{"name":"legacy","version":1,"specs":[{"shutterSeconds":0.01,"iso":100}],"generator":{"manual":{}},"perSensorEVOffsetStops":{}}}"#
        let entry = try JSONDecoder().decode(ShotListEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.index, 2)
        XCTAssertEqual(entry.dwellSeconds, 0)
        XCTAssertNil(entry.minimumGapSeconds)
        XCTAssertEqual(entry.captureSet.firing, .hardwareBracket)
        XCTAssertNil(entry.captureSet.executionMode)
    }

    func testEntryTimingSurvivesCodableAndBothReorderHelpers() throws {
        let entries = [
            ShotListEntry(index: 7, sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0.1),
            ShotListEntry(index: 8, sensor: .telephoto, captureSet: recipeSet(firing: .sequential),
                          dwellSeconds: 0.2, minimumGapSeconds: 0.5),
            ShotListEntry(index: 9, sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0.3)
        ]
        XCTAssertEqual(try JSONDecoder().decode([ShotListEntry].self,
            from: JSONEncoder().encode(entries)), entries)
        let authored = ShotList.authored(entries)
        XCTAssertEqual(authored.map(\.index), [0, 1, 2])
        XCTAssertEqual(authored.map(\.dwellSeconds), [0.1, 0.2, 0.3])
        XCTAssertEqual(authored.map(\.minimumGapSeconds), [nil, 0.5, nil])
        let grouped = ShotList.grouped(entries)
        XCTAssertEqual(grouped.map(\.index), [0, 1, 2])
        XCTAssertEqual(grouped.map(\.dwellSeconds), [0.1, 0.3, 0.2])
        XCTAssertEqual(grouped.map(\.minimumGapSeconds), [nil, nil, 0.5])
    }
}

// Shared, deterministic fixtures use the actual CaptureSet and capability types.
func recipeSet(specs: [CaptureSpec]? = nil, count: Int = 1,
               firing: ExecutionMode = .hardwareBracket,
               offsets: [String: Double] = [:]) -> CaptureSet {
    CaptureSet(name: "series", version: 2,
               specs: specs ?? Array(repeating: CaptureSpec(shutterSeconds: 0.01, iso: 100), count: count),
               generator: .manual, perSensorEVOffsetStops: offsets, executionMode: firing)
}

func recipeFixture(steps: [RecipeStep]) -> Recipe {
    Recipe(id: UUID(), name: "Original", version: 3,
           createdAt: Date(timeIntervalSince1970: 100), modifiedAt: Date(timeIntervalSince1970: 200),
           steps: steps, note: "operator note", schemaVersion: 1)
}
