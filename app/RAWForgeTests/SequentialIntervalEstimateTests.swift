import XCTest
@testable import RAWForge

final class SequentialIntervalEstimateTests: XCTestCase {
    func testIntervalChargesOnlyResidualTimeAfterPreviousFrame() throws {
        // Three 1 s exposures, 3 x .233 s pipeline and .4 s setup = 4.099 s.
        // A .5 s start-to-start floor adds nothing; a 2 s floor adds .767
        // between each pair, never before the first or after the last frame.
        for (interval, gaps, total) in [(0.5, 0.0, 4.099), (2.0, 1.534, 5.633)] {
            let step = try RecipeStep.validated(sensor: .wide,
                captureSet: recipeSet(specs: Array(repeating: .init(shutterSeconds: 1, iso: 100), count: 3),
                                      firing: .sequential), sequentialGapSeconds: interval)
            let estimate = SessionEstimate.forShotList(recipeFixture(steps: [step]).renderedEntries(),
                minimumGap: 0, includeStillness: false, profile: .reference)
            XCTAssertEqual(estimate.breakdown.gaps, gaps, accuracy: 0.000001)
            XCTAssertEqual(estimate.typicalSeconds, total, accuracy: 0.000001)
        }
    }

    func testUnequalExposuresUsePreviousRenderedFrameForEachInterval() throws {
        // Rendered shutters are .2, 2, .4 s after the 1-stop offset.
        // Only the first interval needs padding: 1 - (.2 + .233) = .567 s.
        let step = try RecipeStep.validated(sensor: .wide,
            captureSet: recipeSet(specs: [0.1, 1, 0.2].map { .init(shutterSeconds: $0, iso: 100) },
                                  firing: .sequential, offsets: [SensorCapability.Sensor.wide.rawValue: 1]),
            sequentialGapSeconds: 1)
        let estimate = SessionEstimate.forShotList(recipeFixture(steps: [step]).renderedEntries(),
            minimumGap: 0, includeStillness: false, profile: .reference)
        XCTAssertEqual(estimate.breakdown.gaps, 0.567, accuracy: 0.000001)
        XCTAssertEqual(estimate.typicalSeconds, 4.266, accuracy: 0.000001)
    }

    func testLegacyIntervalNeverWaitsBeforeFirstFrame() {
        let entry = ShotListEntry(index: 0, sensor: .wide,
            captureSet: recipeSet(count: 1, firing: .sequential))
        let estimate = SessionEstimate.forShotList([entry], minimumGap: 5,
            includeStillness: false, profile: .reference)
        XCTAssertEqual(estimate.breakdown.gaps, 0)
        XCTAssertEqual(estimate.typicalSeconds, 0.643, accuracy: 0.000001)
    }
}
