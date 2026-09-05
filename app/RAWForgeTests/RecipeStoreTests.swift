import XCTest
@testable import RAWForge

final class RecipeStoreTests: XCTestCase {
    private var root: URL!
    private var store: RecipeStore!
    private var selection: SelectedRecipeStore!
    private let now = Date(timeIntervalSince1970: 500)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        selection = SelectedRecipeStore(url: root.appendingPathComponent("support/selected-recipe.json"))
        store = RecipeStore(root: root.appendingPathComponent("recipes"), selection: selection,
                            migrationURL: root.appendingPathComponent("support/recipe-migration-v1.json"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testSavingStaleDraftAppendsWithoutOverwritingAnyEarlierVersion() throws {
        let original = try store.create(draft(), now: now)
        let bytes = try Data(contentsOf: versionURL(original))
        var edited = original
        edited.name = "Edited"
        edited.steps.append(try .validated(sensor: .telephoto, captureSet: recipeSet(firing: .sequential)))
        let second = try store.saveVersion(edited, now: now.addingTimeInterval(1))
        let third = try store.saveVersion(original, now: now.addingTimeInterval(2))
        XCTAssertEqual([original.version, second.version, third.version], [1, 2, 3])
        XCTAssertEqual(try Data(contentsOf: versionURL(original)), bytes)
        XCTAssertEqual(try store.load(id: original.id, version: 2)?.steps.count, 2)
        XCTAssertEqual(try store.all().map(\.version), [3])
        XCTAssertEqual(second.createdAt, original.createdAt)
        XCTAssertThrowsError(try store.create(original, now: now))
    }

    func testDuplicateHasIndependentIdentityAndArchivingDoesNotRewriteDefinitions() throws {
        let original = try store.create(draft(), now: now)
        let bytes = try Data(contentsOf: versionURL(original))
        let copy = try store.duplicate(original, now: now)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Original Copy")
        XCTAssertEqual(copy.version, 1)
        XCTAssertEqual(copy.steps, original.steps)
        try store.archive(id: original.id, archived: true)
        XCTAssertEqual(try store.all().map(\.id), [copy.id])
        XCTAssertEqual(try store.all(includeArchived: true).count, 2)
        XCTAssertEqual(try Data(contentsOf: versionURL(original)), bytes)
        try store.archive(id: original.id, archived: false)
        XCTAssertEqual(try store.all().count, 2)
    }

    func testDeleteRefusesSelectedIdentityEvenWhenAnotherVersionIsSelected() throws {
        let original = try store.create(draft(), now: now)
        let second = try store.saveVersion(original, now: now)
        try selection.save(second)
        XCTAssertThrowsError(try store.delete(id: original.id))
        XCTAssertNotNil(try store.load(id: original.id, version: 1))
        let copy = try store.duplicate(original, now: now)
        try selection.save(copy)
        try store.delete(id: original.id)
        XCTAssertNil(try store.load(id: original.id, version: 1))
        XCTAssertEqual(try store.all().map(\.id), [copy.id])
    }

    func testSelectionPinsAVersionAndCorruptSelectionRecoversACompatibleStarter() throws {
        let original = try store.create(draft(), now: now)
        try selection.save(original)
        _ = try store.saveVersion(original, now: now)
        XCTAssertEqual(try store.ensureStarterSelected(report: recipeStorageReport(), now: now).version, 1)
        try Data("broken".utf8).write(to: root.appendingPathComponent("support/selected-recipe.json"))
        let recovered = try store.ensureStarterSelected(report: recipeStorageReport(), now: now)
        XCTAssertEqual(try selection.load()?.recipeID, recovered.id)
        XCTAssertTrue(RecipeValidator.validate(recovered, against: recipeStorageReport()).canCapture)
        XCTAssertEqual(try store.all().count, 2, "do not silently select a different authored recipe")
        try selection.clear()
        XCTAssertEqual(try store.ensureStarterSelected(report: recipeStorageReport(), now: now).id, recovered.id)
        XCTAssertEqual(try store.all().count, 2, "reuse the compatible starter after relaunch")
    }

    func testStarterUsesOnlyAvailableSensorAndItsActualRails() throws {
        let report = recipeStorageReport(sensor: .telephoto, minISO: 200, minShutter: 0.02)
        let starter = try store.ensureStarterSelected(report: report, now: now)
        XCTAssertEqual(starter.steps.map(\.sensor), [.telephoto])
        XCTAssertEqual(starter.steps[0].captureSet.specs, [.init(shutterSeconds: 0.02, iso: 200)])
        XCTAssertFalse(RecipeValidator.validate(starter, against: report).hasWarnings)
        let empty = CapabilityReport(device: report.device, sensors: [.absent(.wide)])
        try selection.clear()
        XCTAssertThrowsError(try store.ensureStarterSelected(report: empty, now: now))
        XCTAssertEqual(try store.all().count, 1)
    }

    func testFutureOrMismatchedVersionIsNotLoadedAsCurrentOrOverwritten() throws {
        let recipe = try store.create(draft(), now: now)
        let url = versionURL(recipe)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: url)
        XCTAssertThrowsError(try store.load(id: recipe.id, version: 1))
        XCTAssertThrowsError(try store.saveVersion(recipe, now: now))
        XCTAssertEqual(try Data(contentsOf: url), future)
        json["schemaVersion"] = 1
        json["version"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try store.load(id: recipe.id, version: 1))
    }

    func testInvalidDraftAndFailedWriteLeavePreviousVersionsIntact() throws {
        let recipe = try store.create(draft(), now: now)
        var invalid = recipe
        invalid.steps[0].dwellSeconds = -1
        XCTAssertThrowsError(try store.saveVersion(invalid, now: now))
        let blocked = RecipeStore(root: root.appendingPathComponent("recipes"), selection: selection,
            migrationURL: root.appendingPathComponent("support/recipe-migration-v1.json"),
            beforeCommit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try blocked.saveVersion(recipe, now: now))
        XCTAssertEqual(try store.all().map(\.version), [1])
        XCTAssertEqual(try store.load(id: recipe.id, version: 1), recipe)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: versionURL(recipe).deletingLastPathComponent().path)
        XCTAssertEqual(remaining, ["v0001.json"])
    }

    func testMigrationPreservesAuthoredOrderFiringAndTimingAndClearsOnlyAfterSelection() throws {
        let legacy = ShotListStore.Stored(entries: [
            .init(index: 0, sensor: .telephoto, captureSet: recipeSet(firing: .sequential)),
            .init(index: 1, sensor: .wide, captureSet: recipeSet(count: 16))
        ], groupedBySensor: false, savedAt: now)
        var cleared = false
        let imported = try XCTUnwrap(store.migrateShotListIfNeeded(legacy, now: now,
            dwellSeconds: 0.2, sequentialGapSeconds: 0.5, clearLegacy: {
                let selected = try XCTUnwrap(self.selection.load())
                XCTAssertNotNil(try self.store.load(id: selected.recipeID, version: selected.version))
                cleared = true
            }))
        XCTAssertTrue(cleared)
        XCTAssertEqual(imported.steps.map(\.sensor), [.telephoto, .wide])
        XCTAssertEqual(imported.steps.map(\.captureSet), legacy.entries.map(\.captureSet))
        XCTAssertEqual(imported.steps.map(\.dwellSeconds), [0.2, 0.2])
        XCTAssertEqual(imported.steps.map(\.sequentialGapSeconds), [0.5, nil])
        XCTAssertNil(try store.migrateShotListIfNeeded(legacy, now: now, clearLegacy: { XCTFail("already migrated") }))
        XCTAssertEqual(try store.all().count, 1)
    }

    func testInterruptedMigrationRetriesSameIdentityAndNeverClearsBeforePersisting() throws {
        let legacy = ShotListStore.Stored(entries: try draft().renderedEntries(), groupedBySensor: false, savedAt: now)
        let blocked = RecipeStore(root: root.appendingPathComponent("recipes"), selection: selection,
            migrationURL: root.appendingPathComponent("support/recipe-migration-v1.json"),
            beforeCommit: { url in if url.lastPathComponent == "v0001.json" { throw CocoaError(.fileWriteOutOfSpace) } })
        XCTAssertThrowsError(try blocked.migrateShotListIfNeeded(legacy, now: now, clearLegacy: { XCTFail("too early") }))
        XCTAssertTrue(try store.all().isEmpty)
        XCTAssertThrowsError(try store.migrateShotListIfNeeded(legacy, now: now,
            clearLegacy: { throw CocoaError(.fileWriteNoPermission) }))
        let pendingID = try XCTUnwrap(store.all().first?.id)
        let recovered = try XCTUnwrap(store.migrateShotListIfNeeded(nil, now: now, clearLegacy: {}))
        XCTAssertEqual(recovered.id, pendingID)
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(recovered.steps[0].dwellSeconds, 0)
        XCTAssertNil(recovered.steps[0].sequentialGapSeconds)
    }

    func testExistingRecipesPreventImportWithoutDeletingLegacyDraft() throws {
        _ = try store.create(draft(), now: now)
        let legacy = ShotListStore.Stored(entries: try draft().renderedEntries(), groupedBySensor: false, savedAt: now)
        XCTAssertNil(try store.migrateShotListIfNeeded(legacy, now: now, clearLegacy: { XCTFail("must retain") }))
    }

    private func draft() throws -> Recipe {
        recipeFixture(steps: [try .validated(sensor: .wide, captureSet: recipeSet())])
    }

    private func versionURL(_ recipe: Recipe) -> URL {
        root.appendingPathComponent("recipes/\(recipe.id.uuidString)/v0001.json")
    }
}

func recipeStorageReport(sensor: SensorCapability.Sensor = .wide, minISO: Float = 50,
                         minShutter: Double = 0.001) -> CapabilityReport {
    CapabilityReport(device: DeviceIdentity(modelIdentifier: "iPhone16,1", systemName: "iOS",
        systemVersion: "26.5", appVersion: "1", appBuild: "1", appCommit: nil, isSimulator: true),
        sensors: [SensorCapability(sensor: sensor, localizedName: "Camera", uniqueID: "test", modelID: "test",
            bayerFormat: 1650943796, allRawFormats: [], rawFormatsRequiredRunningSession: false,
            exclusionReason: nil, supportsCustomExposure: true, supportsWhiteBalanceCustomGainLock: true,
            supportsLockedFocus: true, supportsCustomLensPosition: true, supportsFocusPointOfInterest: true,
            minimumFocusDistanceMillimetres: 120, horizontalFieldOfViewDegrees: 69,
            maxBracketedCapturePhotoCount: 8, maxWhiteBalanceGain: 4, minAvailableVideoZoomFactor: 1,
            minISO: minISO, maxISO: 800, minExposureSeconds: minShutter, maxExposureSeconds: 1)])
}
