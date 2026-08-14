import XCTest
@testable import RAWForge

final class SessionEstimateTests: XCTestCase {

    private func entry(_ sensor: SensorCapability.Sensor, shutter: Double, frames: Int) -> ShotListEntry {
        ShotListEntry(index: 0, sensor: sensor,
                      captureSet: .repeated(CaptureSpec(shutterSeconds: shutter, iso: 100), count: frames))
    }

    /// A bracket holds a frame period per frame unless the exposure is longer,
    /// which is the measured `gap = max(33.4 ms, exposure)` (#14 item 9).
    func testBracketOverheadIsTheFramePeriodForShortExposures() {
        let e = SessionEstimate.forShotList([entry(.wide, shutter: 0.001, frames: 8)],
                                            mode: .hardwareBracket, minimumGap: 0,
                                            includeStillness: false)
        XCTAssertEqual(e.frameCount, 8)
        // 8 frames x (33.4 ms - 1 ms) of overhead, plus one swap.
        let expected = DeviceProfile.reference.sensorSwap.value + 8 * (DeviceProfile.reference.sensorFramePeriod.value - 0.001)
        XCTAssertEqual(e.overheadSeconds, expected, accuracy: 1e-9)
    }

    func testLongExposuresAbsorbTheFramePeriod() {
        let e = SessionEstimate.forShotList([entry(.wide, shutter: 0.5, frames: 4)],
                                            mode: .hardwareBracket, minimumGap: 0,
                                            includeStillness: false)
        // Exposure exceeds the frame period, so no per-frame overhead remains.
        XCTAssertEqual(e.overheadSeconds, DeviceProfile.reference.sensorSwap.value, accuracy: 1e-9)
        XCTAssertEqual(e.exposureSeconds, 2.0, accuracy: 1e-9)
    }

    /// Sequential pays a per-request round trip that a bracket does not — the
    /// measured reason a bracket is ~7x faster for the same ladder.
    func testSequentialIsSlowerThanBracketForTheSameLadder() {
        let list = [entry(.wide, shutter: 0.001, frames: 8)]
        let bracket = SessionEstimate.forShotList(list, mode: .hardwareBracket,
                                                  minimumGap: 0, includeStillness: false)
        let sequential = SessionEstimate.forShotList(list, mode: .sequential,
                                                     minimumGap: 0, includeStillness: false)
        XCTAssertGreaterThan(sequential.typicalSeconds, bracket.typicalSeconds * 3)
    }

    func testSwapIsCountedOncePerSensorRunNotPerEntry() {
        let list = [entry(.wide, shutter: 0.001, frames: 1),
                    entry(.wide, shutter: 0.001, frames: 1),
                    entry(.telephoto, shutter: 0.001, frames: 1)]
        let e = SessionEstimate.forShotList(list, mode: .hardwareBracket,
                                            minimumGap: 0, includeStillness: false)
        XCTAssertEqual(e.sensorSwaps, 2, "consecutive entries on one sensor share a swap")
    }

    /// Storage is judged on the worst case: "probably fits" is not worth having
    /// when the failure is a station aborting mid-shoot.
    func testWorstCaseStorageUsesTheLargestObservedFrame() {
        let e = SessionEstimate.forShotList([entry(.wide, shutter: 0.001, frames: 10)],
                                            mode: .hardwareBracket, minimumGap: 0)
        XCTAssertEqual(e.typicalBytes, 100_000_000)
        XCTAssertEqual(e.worstCaseBytes, 307_000_000)
        XCTAssertGreaterThan(e.worstCaseBytes, e.typicalBytes)
    }

    func testDurationFormattingCrossesUnitsCleanly() {
        XCTAssertEqual(SessionEstimate.formatDuration(0.033), "33 ms")
        XCTAssertEqual(SessionEstimate.formatDuration(2.5), "2.5 s")
        XCTAssertEqual(SessionEstimate.formatDuration(125), "2 min 05 s")
    }
}

final class DarkFrameValidationTests: XCTestCase {

    /// Buffer units: black 528 x 4 = 2112, ceiling 4095 x 4 = 16380.
    private func stats(p50: Int, p999: Int) -> ClippingStats {
        let ch = (0..<4).map { i in
            ClippingStats.Channel(
                cfaPosition: i, colour: "G", count: 3_048_192,
                min: 2069, max: p999 + 20, mean: Double(p50),
                p50: p50, p90: p50, p99: p999, p999: p999,
                countAtMax: 1, modeValue: p50, modeCount: 1_000_000,
                fractionAtOrAboveDeclaredWhite: 0, fractionAtOrAboveObservedCeiling: 0,
                fractionAtOrBelowBlack: 0, p50Normalised: 0, p99Normalised: 0,
                histogram256: [])
        }
        return ClippingStats(
            unavailableReason: nil, pixelFormat: "'bgg4'", bufferWidth: 4224, bufferHeight: 3024,
            activeArea: [0, 0, 3024, 4032], croppedWidth: 4032, croppedHeight: 3024,
            declaredBlackLevel: 528, declaredWhiteLevel: 4095,
            bufferScaleOverDNG: 4, channels: ch)
    }

    /// Measured: a capped frame's median sits at exactly the pedestal.
    func testCappedFramePasses() {
        let v = DarkFrameValidation.check(stats(p50: 2112, p999: 2136))
        XCTAssertEqual(v?.passed, true)
        XCTAssertNil(v?.failureReason)
    }

    /// Measured: an uncapped frame at 1/250 s sat 14-29 counts above the
    /// pedestal on the median. That must be refused.
    func testDimUncappedFrameIsRefusedOnTheMedian() {
        let v = DarkFrameValidation.check(stats(p50: 2141, p999: 2270))
        XCTAssertEqual(v?.passed, false)
        XCTAssertTrue(v?.failureReason?.contains("median") ?? false,
                      "the median is the discriminating statistic, not the tail")
    }

    /// The original tail-only bar let that same frame through, which is the
    /// regression this test exists to prevent.
    func testTailAloneWouldHaveAdmittedIt() {
        let tailExcess = (2270.0 - 2112.0) / (16380.0 - 2112.0)
        XCTAssertLessThan(tailExcess, 0.02, "1.1% — under the old 2% tail bar")
    }

    func testDarkCurrentAtOneSecondStillPasses() {
        // Measured: mean rose to 2112.21 at 1 s and the median never moved.
        XCTAssertEqual(DarkFrameValidation.check(stats(p50: 2112, p999: 2136))?.passed, true)
    }

    func testMissingStatisticsYieldNoVerdictRatherThanAPass() {
        XCTAssertNil(DarkFrameValidation.check(.unavailable("no pixel buffer")))
    }
}

final class EstimateCalibrationTests: XCTestCase {

    func testIdentityWhenThereIsNoHistory() {
        let c = EstimateCalibration.identity
        XCTAssertEqual(c.apply(10), 10)
        XCTAssertNil(c.summary)
    }

    /// Below the sample floor the correction is noise and must not be applied.
    func testTooFewSamplesAreNotApplied() {
        let c = EstimateCalibration(factor: 1.8, sampleCount: 2)
        XCTAssertFalse(c.isUseful)
        XCTAssertEqual(c.apply(10), 10, "a two-sample correction would make the estimate worse")
    }

    func testCorrectionAppliesOnceThereIsEnoughHistory() {
        let c = EstimateCalibration(factor: 1.4, sampleCount: 6)
        XCTAssertTrue(c.isUseful)
        XCTAssertEqual(c.apply(10), 14, accuracy: 1e-9)
        XCTAssertTrue(c.summary?.contains("+40%") ?? false)
    }

    func testSmallDriftIsReportedAsTracking() {
        XCTAssertTrue(EstimateCalibration(factor: 1.02, sampleCount: 8)
            .summary?.contains("tracking") ?? false)
    }
}

/// A set longer than the sensor's hardware bracket ceiling is split across
/// requests, and each seam costs seventeen times an in-request gap. A plan that
/// ignored that would badly under-estimate any long set.
final class BracketSeamEstimateTests: XCTestCase {

    private func entry(frames: Int) -> ShotListEntry {
        ShotListEntry(
            index: 0, sensor: .wide,
            captureSet: .repeated(CaptureSpec(shutterSeconds: 1.0 / 250, iso: 100),
                                  count: frames, name: "repeat"))
    }

    func testASetInsideTheCeilingHasNoSeams() {
        let e = SessionEstimate.forShotList([entry(frames: 8)], mode: .hardwareBracket,
                                            minimumGap: 0, bracketCeiling: 8,
                                            profile: .reference)
        XCTAssertEqual(e.bracketSeams, 0)
    }

    func testSixteenFramesOnAnEightCeilingCostsOneSeam() {
        let e = SessionEstimate.forShotList([entry(frames: 16)], mode: .hardwareBracket,
                                            minimumGap: 0, bracketCeiling: 8,
                                            profile: .reference)
        XCTAssertEqual(e.bracketSeams, 1)
        let without = SessionEstimate.forShotList([entry(frames: 16)], mode: .hardwareBracket,
                                                  minimumGap: 0, bracketCeiling: nil,
                                                  profile: .reference)
        XCTAssertEqual(e.typicalSeconds - without.typicalSeconds,
                       DeviceProfile.reference.bracketSeam.value, accuracy: 0.001)
    }

    func testSeamsScaleWithHowFarPastTheCeilingTheSetGoes() {
        for (frames, seams) in [(9, 1), (16, 1), (17, 2), (24, 2), (64, 7)] {
            let e = SessionEstimate.forShotList([entry(frames: frames)], mode: .hardwareBracket,
                                                minimumGap: 0, bracketCeiling: 8)
            XCTAssertEqual(e.bracketSeams, seams, "\(frames) frames on a ceiling of 8")
        }
    }

    /// Sequential reconfigures per rung and issues one request per frame, so
    /// there is no bracket boundary to pay for.
    func testSequentialHasNoSeamsAtAll() {
        let e = SessionEstimate.forShotList([entry(frames: 64)], mode: .sequential,
                                            minimumGap: 0, bracketCeiling: 8,
                                            profile: .reference)
        XCTAssertEqual(e.bracketSeams, 0)
    }

    func testRequestCountRoundsUpAndSurvivesNonsense() {
        XCTAssertEqual(SessionEstimate.requestCount(frames: 16, ceiling: 8), 2)
        XCTAssertEqual(SessionEstimate.requestCount(frames: 17, ceiling: 8), 3)
        XCTAssertEqual(SessionEstimate.requestCount(frames: 1, ceiling: 8), 1)
        XCTAssertEqual(SessionEstimate.requestCount(frames: 8, ceiling: 0), 0,
                       "a ceiling of zero must not divide by zero")
        XCTAssertEqual(SessionEstimate.requestCount(frames: 0, ceiling: 8), 0)
    }
}
