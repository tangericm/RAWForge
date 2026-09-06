import XCTest
@testable import RAWForge

final class TimingSafetyTests: XCTestCase {
    func testSleepConversionPreservesUnitsAndSubsecondTiming() throws {
        let cases: [(Double, UInt64)] = [
            (0, 0), (0.000_000_001, 1), (0.5, 500_000_000),
            (1.25, 1_250_000_000), (18_000_000_000, 18_000_000_000_000_000_000)
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(try CaptureTiming.nanoseconds(for: seconds), expected)
        }
        // The immediately preceding representable Double is still safe, unlike
        // the upper value rounded to 2^64 by nanosecond conversion.
        let lastSafeSeconds = (Double(UInt64.max) / 1_000_000_000).nextDown
        XCTAssertLessThan(try CaptureTiming.nanoseconds(for: lastSafeSeconds), UInt64.max)
    }

    func testUnrepresentableWaitAndIntervalAreRejected() {
        let invalid: [Double] = [-1, .nan, .infinity, -.infinity,
            20_000_000_000, 1e20, Double(UInt64.max) / 1_000_000_000]
        for seconds in invalid {
            XCTAssertThrowsError(try RecipeStep.validated(sensor: .wide,
                captureSet: recipeSet(), dwellSeconds: seconds), "wait: \(seconds)")
            XCTAssertThrowsError(try RecipeStep.validated(sensor: .wide,
                captureSet: recipeSet(firing: .sequential),
                sequentialGapSeconds: seconds), "interval: \(seconds)")
        }
    }

    func testRepresentableTimingSurvivesRecipeRoundTrip() throws {
        // Includes a long but representable duration; this is a clock safety
        // boundary, not an arbitrary limit on the user's capture workflow.
        for seconds in [0, 0.000_000_001, 0.5, 86_400, 18_000_000_000] {
            let step = try RecipeStep.validated(sensor: .wide,
                captureSet: recipeSet(firing: .sequential), dwellSeconds: seconds,
                sequentialGapSeconds: seconds)
            let restored = try JSONDecoder().decode(Recipe.self,
                from: JSONEncoder().encode(recipeFixture(steps: [step])))
            XCTAssertEqual(restored.steps[0].dwellSeconds, seconds)
            XCTAssertEqual(restored.steps[0].sequentialGapSeconds, seconds)
            XCTAssertTrue(restored.steps[0].validationErrors.isEmpty)
        }
    }

    func testDecodedUnsafeTimingBlocksCapture() throws {
        // Decoding bypasses the factory, as do edits of an existing draft.
        let step = RecipeStep(id: UUID(), sensor: .wide,
            captureSet: recipeSet(firing: .sequential), dwellSeconds: 1e20,
            sequentialGapSeconds: 20_000_000_000)
        let restored = try JSONDecoder().decode(Recipe.self,
            from: JSONEncoder().encode(recipeFixture(steps: [step])))
        XCTAssertEqual(restored.steps[0].validationErrors, [.invalidDwell, .invalidSequentialGap])
        XCTAssertFalse(RecipeValidator.validate(restored, against: recipeStorageReport()).canCapture)
    }

    func testDurationDisplayHandlesInvalidValuesAndLargeMinuteCounts() {
        for seconds in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(SessionEstimate.formatDuration(seconds), "Unavailable")
        }
        XCTAssertEqual(SessionEstimate.formatDuration(0), "0 ms")
        XCTAssertEqual(SessionEstimate.formatDuration(0.125), "125 ms")
        XCTAssertEqual(SessionEstimate.formatDuration(1.5), "1.5 s")
        XCTAssertEqual(SessionEstimate.formatDuration(61), "1 min 01 s")
        XCTAssertEqual(SessionEstimate.formatDuration(1e15), "16666666666666 min 40 s")
    }

    func testExtremeDecodedWaitCanBeDisplayedWithoutIntegerOverflow() throws {
        let step = RecipeStep(id: UUID(), sensor: .wide, captureSet: recipeSet(),
            dwellSeconds: 1e20, sequentialGapSeconds: nil)
        let restored = try JSONDecoder().decode(Recipe.self,
            from: JSONEncoder().encode(recipeFixture(steps: [step])))
        let estimate = SessionEstimate.forShotList(restored.renderedEntries(),
            minimumGap: 0, profile: .reference)
        XCTAssertEqual(SessionEstimate.formatDuration(estimate.worstCaseSeconds), "1e+20 s")
        XCTAssertFalse(SessionEstimate.formatDuration(Double.greatestFiniteMagnitude).isEmpty)
        XCTAssertFalse(SessionEstimate.formatDuration(Double(Int.max)).isEmpty)
    }
}
