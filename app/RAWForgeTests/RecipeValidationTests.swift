import XCTest
@testable import RAWForge

final class RecipeValidationTests: XCTestCase {
    func testValidationReportsOrderedRenderedRailsWithoutMutatingDraft() throws {
        let set = recipeSet(specs: [.init(shutterSeconds: 0.1, iso: 100),
                                   .init(shutterSeconds: 0.6, iso: 100),
                                   .init(shutterSeconds: 0.1, iso: 20)], offsets: ["tele": 1])
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .telephoto, captureSet: set, dwellSeconds: 0),
            try .validated(sensor: .wide, captureSet: recipeSet(count: 16), dwellSeconds: 0)
        ])
        let original = recipe
        let result = RecipeValidator.validate(recipe, against: report())
        XCTAssertTrue(result.canCapture)
        XCTAssertTrue(result.hasWarnings)
        XCTAssertEqual(result.steps.map(\.stepID), recipe.steps.map(\.id))
        XCTAssertEqual(result.steps.map(\.stepIndex), [0, 1])
        XCTAssertEqual(result.steps[0].kept, [.init(shutterSeconds: 0.2, iso: 100)])
        XCTAssertEqual(result.steps[0].dropped.map(\.spec), [
            .init(shutterSeconds: 1.2, iso: 100), .init(shutterSeconds: 0.2, iso: 20)])
        XCTAssertEqual(result.steps[0].droppedRungIndices, [1, 2])
        XCTAssertTrue(result.steps[0].dropped.allSatisfy { !$0.reason.isEmpty })
        XCTAssertEqual(result.steps[1].kept.count, 16)
        XCTAssertEqual(recipe, original)
    }

    func testMissingAndUnusablePhysicalSensorsBlockAndCannotBeAdapted() throws {
        let recipe = recipeFixture(steps: [try .validated(sensor: .telephoto,
            captureSet: recipeSet(), dwellSeconds: 0)])
        for sensors in [[sensor(.wide)], [sensor(.wide), .absent(.telephoto)]] {
            let capability = report(sensors: sensors)
            let result = RecipeValidator.validate(recipe, against: capability)
            XCTAssertFalse(result.canCapture)
            XCTAssertFalse(result.steps[0].blockers.isEmpty)
            XCTAssertTrue(result.steps[0].dropped.isEmpty, "missing sensors are not dropped rungs")
            let adaptation = RecipeValidator.adaptedCopy(of: recipe, against: capability, now: now)
            XCTAssertNil(adaptation.recipe)
            XCTAssertTrue(adaptation.changes.isEmpty)
            XCTAssertEqual(adaptation.validation, result)
        }
    }

    func testZeroKeptRungsBlocksTheWholeRecipeAndAdaptation() throws {
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0),
            try .validated(sensor: .telephoto,
                captureSet: recipeSet(specs: [.init(shutterSeconds: 2, iso: 100)]), dwellSeconds: 0)
        ])
        let result = RecipeValidator.validate(recipe, against: report())
        XCTAssertFalse(result.canCapture)
        XCTAssertEqual(result.steps[1].dropped.count, 1)
        XCTAssertTrue(result.steps[1].blockers.contains(.noSupportedRungs))
        XCTAssertNil(RecipeValidator.adaptedCopy(of: recipe, against: report(), now: now).recipe)
    }

    func testEmptyRecipeAndInvalidMutableOrDecodedDraftsAreSafeBlockers() throws {
        XCTAssertFalse(RecipeValidator.validate(recipeFixture(steps: []), against: report()).canCapture)
        let valid = try RecipeStep.validated(sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0)
        var drafts: [RecipeStep] = []
        var burstGap = valid
        burstGap.sequentialGapSeconds = 0
        drafts.append(burstGap)
        for dwell in [-1, Double.nan, .infinity] {
            var draft = valid
            draft.dwellSeconds = dwell
            drafts.append(draft)
        }
        var negativeGap = valid
        negativeGap.captureSet.executionMode = .sequential
        negativeGap.sequentialGapSeconds = -1
        drafts.append(negativeGap)
        var empty = valid
        empty.captureSet = recipeSet(specs: [])
        drafts.append(empty)
        // Codable preserves a draft for validation; it must not trap or silently fix it.
        drafts.append(try JSONDecoder().decode(RecipeStep.self, from: JSONEncoder().encode(burstGap)))
        for draft in drafts {
            let recipe = recipeFixture(steps: [draft])
            let result = RecipeValidator.validate(recipe, against: report())
            XCTAssertFalse(result.canCapture)
            XCTAssertFalse(result.steps[0].blockers.isEmpty)
            XCTAssertNil(RecipeValidator.adaptedCopy(of: recipe, against: report(), now: now).recipe)
        }
    }

    func testInvalidExposureNumbersAreBlockedNotPassedToRailFormattingOrAdaptedAway() throws {
        for spec in [CaptureSpec(shutterSeconds: .nan, iso: 100),
                     .init(shutterSeconds: .infinity, iso: 100),
                     .init(shutterSeconds: 0, iso: 100),
                     .init(shutterSeconds: 0.01, iso: .nan),
                     .init(shutterSeconds: 0.01, iso: -.infinity),
                     .init(shutterSeconds: 0.01, iso: -1)] {
            var step = try RecipeStep.validated(sensor: .wide, captureSet: recipeSet(), dwellSeconds: 0)
            step.captureSet = recipeSet(specs: [spec])
            let recipe = recipeFixture(steps: [step])
            XCTAssertFalse(RecipeValidator.validate(recipe, against: report()).canCapture)
            XCTAssertNil(RecipeValidator.adaptedCopy(of: recipe, against: report(), now: now).recipe)
        }
    }

    func testNonfiniteSensorOffsetBlocksWithoutInventingAnExposure() throws {
        let step = try RecipeStep.validated(sensor: .telephoto,
            captureSet: recipeSet(offsets: ["tele": .infinity]), dwellSeconds: 0)
        let recipe = recipeFixture(steps: [step])
        XCTAssertFalse(RecipeValidator.validate(recipe, against: report()).canCapture)
        XCTAssertNil(RecipeValidator.adaptedCopy(of: recipe, against: report(), now: now).recipe)
    }

    func testAdaptationRemovesOnlyReportedOccurrencesAndPreservesCanonicalOffsetsAndFiring() throws {
        let low = CaptureSpec(shutterSeconds: 0.1, iso: 100)
        let high = CaptureSpec(shutterSeconds: 0.6, iso: 100)
        let set = recipeSet(specs: [low, high, low, high], firing: .sequential, offsets: ["tele": 1])
        let recipe = recipeFixture(steps: [
            try .validated(sensor: .telephoto, captureSet: set, dwellSeconds: 0.2, sequentialGapSeconds: 0.5),
            try .validated(sensor: .wide, captureSet: recipeSet(count: 16), dwellSeconds: 0)
        ])
        let original = recipe
        let adaptation = RecipeValidator.adaptedCopy(of: recipe, against: report(), now: now)
        let copy = try XCTUnwrap(adaptation.recipe)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.version, 1)
        XCTAssertEqual(copy.name, "Original (iPhone16,1)")
        XCTAssertEqual(copy.createdAt, now)
        XCTAssertEqual(copy.modifiedAt, now)
        XCTAssertEqual(copy.schemaVersion, original.schemaVersion)
        XCTAssertEqual(copy.note, original.note)
        XCTAssertEqual(copy.steps.map(\.id), original.steps.map(\.id))
        XCTAssertEqual(copy.steps[0].captureSet.specs, [low, low])
        XCTAssertEqual(copy.steps[0].captureSet.perSensorEVOffsetStops, ["tele": 1])
        XCTAssertEqual(copy.steps[0].captureSet.generator, original.steps[0].captureSet.generator)
        XCTAssertEqual(copy.steps[0].captureSet.firing, .sequential)
        XCTAssertEqual(copy.steps[0].dwellSeconds, 0.2)
        XCTAssertEqual(copy.steps[0].sequentialGapSeconds, 0.5)
        XCTAssertEqual(copy.steps[1], original.steps[1])
        XCTAssertEqual(adaptation.changes.map(\.rungIndex), [1, 3])
        XCTAssertEqual(adaptation.changes.map(\.stepIndex), [0, 0])
        XCTAssertEqual(adaptation.changes.map(\.stepID), [recipe.steps[0].id, recipe.steps[0].id])
        XCTAssertEqual(adaptation.changes.map(\.sensor), [.telephoto, .telephoto])
        XCTAssertEqual(adaptation.changes.map(\.authoredSpec), [high, high])
        XCTAssertEqual(adaptation.changes.map(\.dropped), adaptation.validation.steps[0].dropped)
        let revalidated = RecipeValidator.validate(copy, against: report())
        XCTAssertTrue(revalidated.canCapture)
        XCTAssertFalse(revalidated.hasWarnings)
        XCTAssertEqual(revalidated.steps[0].kept, [.init(shutterSeconds: 0.2, iso: 100),
                                                 .init(shutterSeconds: 0.2, iso: 100)])
        XCTAssertEqual(recipe, original)
    }

    func testCompatibleRecipeAdaptationStillCreatesANewCopyWithNoRungChanges() throws {
        let recipe = recipeFixture(steps: [try .validated(sensor: .wide,
            captureSet: recipeSet(), dwellSeconds: 0)])
        let adaptation = RecipeValidator.adaptedCopy(of: recipe, against: report(), now: now)
        let copy = try XCTUnwrap(adaptation.recipe)
        XCTAssertNotEqual(copy.id, recipe.id)
        XCTAssertEqual(copy.steps, recipe.steps)
        XCTAssertTrue(adaptation.changes.isEmpty)
    }

    private let now = Date(timeIntervalSince1970: 300)

    private func report(sensors: [SensorCapability]? = nil) -> CapabilityReport {
        CapabilityReport(device: DeviceIdentity(modelIdentifier: "iPhone16,1", systemName: "iOS",
            systemVersion: "26.5", appVersion: "1", appBuild: "1", appCommit: nil, isSimulator: true),
            sensors: sensors ?? [sensor(.wide), sensor(.telephoto)])
    }

    private func sensor(_ sensor: SensorCapability.Sensor) -> SensorCapability {
        SensorCapability(sensor: sensor, localizedName: "Camera", uniqueID: sensor.rawValue, modelID: "m",
            bayerFormat: 1650943796, allRawFormats: [], rawFormatsRequiredRunningSession: false,
            exclusionReason: nil, supportsCustomExposure: true, supportsWhiteBalanceCustomGainLock: true,
            supportsLockedFocus: true, supportsCustomLensPosition: true, supportsFocusPointOfInterest: true,
            minimumFocusDistanceMillimetres: 120, horizontalFieldOfViewDegrees: 69,
            maxBracketedCapturePhotoCount: 8, maxWhiteBalanceGain: 4, minAvailableVideoZoomFactor: 1,
            minISO: 50, maxISO: 800, minExposureSeconds: 0.001, maxExposureSeconds: 1)
    }
}
