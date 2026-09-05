import XCTest
@testable import RAWForge

final class RecipeStepSummaryTests: XCTestCase {
    func testSummaryUsesCameraAdjustedExposuresWithoutChangingAuthoredFrames() {
        let set = CaptureSet(name: "Window ladder", version: 1,
            specs: [CaptureSpec(shutterSeconds: 0.004, iso: 100), CaptureSpec(shutterSeconds: 0.008, iso: 200)],
            generator: .manual, perSensorEVOffsetStops: ["1x": 1], executionMode: .hardwareBracket)
        let step = RecipeStep(id: UUID(), sensor: .wide, captureSet: set, dwellSeconds: 0)
        let summary = RecipeStepSummary(step: step)
        XCTAssertEqual(summary.shutterRange, 0.008...0.016)
        XCTAssertEqual(summary.isoRange, 100...200)
        XCTAssertEqual(summary.normalizedExposures, [0.5, 1])
        XCTAssertEqual(step.captureSet.specs[0].shutterSeconds, 0.004)
    }

    func testIntervalIsPresentedOnlyForSequentialIncludingZero() {
        var step = RecipeStep(id: UUID(), sensor: .wide,
            captureSet: .repeated(CaptureSpec(shutterSeconds: 0.01, iso: 100), count: 16),
            dwellSeconds: 0, sequentialGapSeconds: 0.5)
        XCTAssertNil(RecipeStepSummary(step: step).intervalSeconds)
        step.captureSet.executionMode = .sequential
        XCTAssertEqual(RecipeStepSummary(step: step).intervalSeconds, 0.5)
        step.sequentialGapSeconds = 0
        XCTAssertEqual(RecipeStepSummary(step: step).intervalSeconds, 0)
    }

    func testInvalidDraftDoesNotRenderMisleadingRangesOrNonfiniteBars() {
        let set = CaptureSet(name: "Draft", version: 1,
            specs: [CaptureSpec(shutterSeconds: .infinity, iso: 100), CaptureSpec(shutterSeconds: 0, iso: .nan)],
            generator: .manual, perSensorEVOffsetStops: [:], executionMode: .hardwareBracket)
        let summary = RecipeStepSummary(step: RecipeStep(id: UUID(), sensor: .wide, captureSet: set, dwellSeconds: 0))
        XCTAssertNil(summary.shutterRange)
        XCTAssertNil(summary.isoRange)
        XCTAssertTrue(summary.normalizedExposures.isEmpty)
        XCTAssertEqual(summary.exposureText, "Review invalid frame values")
    }
}
