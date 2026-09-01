import XCTest
@testable import RAWForge

final class SessionEstimateTests: XCTestCase {

    private func entry(_ sensor: SensorCapability.Sensor, shutter: Double, frames: Int,
                       firing: ExecutionMode = .hardwareBracket) -> ShotListEntry {
        var set = CaptureSet.repeated(CaptureSpec(shutterSeconds: shutter, iso: 100), count: frames)
        set.executionMode = firing
        return ShotListEntry(index: 0, sensor: sensor, captureSet: set)
    }

    /// A bracket holds a frame period per frame unless the exposure is longer,
    /// which is the measured `gap = max(33.4 ms, exposure)` (#14 item 9).
    func testBracketOverheadIsTheFramePeriodForShortExposures() {
        let e = SessionEstimate.forShotList([entry(.wide, shutter: 0.001, frames: 8)],
                                            minimumGap: 0,
                                            includeStillness: false)
        XCTAssertEqual(e.frameCount, 8)
        // 8 frames x (33.4 ms - 1 ms) of overhead, plus one swap.
        let expected = DeviceProfile.reference.sensorSwap.value + 8 * (DeviceProfile.reference.sensorFramePeriod.value - 0.001)
        XCTAssertEqual(e.overheadSeconds, expected, accuracy: 1e-9)
    }

    func testLongExposuresAbsorbTheFramePeriod() {
        let e = SessionEstimate.forShotList([entry(.wide, shutter: 0.5, frames: 4)],
                                            minimumGap: 0,
                                            includeStillness: false)
        // Exposure exceeds the frame period, so no per-frame overhead remains.
        XCTAssertEqual(e.overheadSeconds, DeviceProfile.reference.sensorSwap.value, accuracy: 1e-9)
        XCTAssertEqual(e.exposureSeconds, 2.0, accuracy: 1e-9)
    }

    /// Sequential pays a per-request round trip that a bracket does not — the
    /// measured reason a bracket is ~7x faster for the same ladder.
    func testSequentialIsSlowerThanBracketForTheSameLadder() {
        let burst = SessionEstimate.forShotList(
            [entry(.wide, shutter: 0.001, frames: 8)],
            minimumGap: 0, includeStillness: false)
        let sequential = SessionEstimate.forShotList(
            [entry(.wide, shutter: 0.001, frames: 8, firing: .sequential)],
            minimumGap: 0, includeStillness: false)
        XCTAssertGreaterThan(sequential.typicalSeconds, burst.typicalSeconds * 3)
    }

    func testSwapIsCountedOncePerSensorRunNotPerEntry() {
        let list = [entry(.wide, shutter: 0.001, frames: 1),
                    entry(.wide, shutter: 0.001, frames: 1),
                    entry(.telephoto, shutter: 0.001, frames: 1)]
        let e = SessionEstimate.forShotList(list,
                                            minimumGap: 0, includeStillness: false)
        XCTAssertEqual(e.sensorSwaps, 2, "consecutive entries on one sensor share a swap")
    }

    /// Storage is judged on the worst case: "probably fits" is not worth having
    /// when the failure is a station aborting mid-shoot.
    func testWorstCaseStorageUsesTheLargestObservedFrame() {
        let e = SessionEstimate.forShotList([entry(.wide, shutter: 0.001, frames: 10)],
                                            minimumGap: 0)
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

    private func entry(frames: Int, firing: ExecutionMode = .hardwareBracket) -> ShotListEntry {
        var set = CaptureSet.repeated(CaptureSpec(shutterSeconds: 1.0 / 250, iso: 100),
                                      count: frames, name: "repeat")
        set.executionMode = firing
        return ShotListEntry(index: 0, sensor: .wide, captureSet: set)
    }

    func testASetInsideTheCeilingHasNoSeams() {
        let e = SessionEstimate.forShotList([entry(frames: 8)], 
                                            minimumGap: 0, bracketCeiling: 8,
                                            profile: .reference)
        XCTAssertEqual(e.bracketSeams, 0)
    }

    func testSixteenFramesOnAnEightCeilingCostsOneSeam() {
        let e = SessionEstimate.forShotList([entry(frames: 16)], 
                                            minimumGap: 0, bracketCeiling: 8,
                                            profile: .reference)
        XCTAssertEqual(e.bracketSeams, 1)
        let without = SessionEstimate.forShotList([entry(frames: 16)], 
                                                  minimumGap: 0, bracketCeiling: nil,
                                                  profile: .reference)
        XCTAssertEqual(e.typicalSeconds - without.typicalSeconds,
                       DeviceProfile.reference.bracketSeam.value, accuracy: 0.001)
    }

    func testSeamsScaleWithHowFarPastTheCeilingTheSetGoes() {
        for (frames, seams) in [(9, 1), (16, 1), (17, 2), (24, 2), (64, 7)] {
            let e = SessionEstimate.forShotList([entry(frames: frames)], 
                                                minimumGap: 0, bracketCeiling: 8)
            XCTAssertEqual(e.bracketSeams, seams, "\(frames) frames on a ceiling of 8")
        }
    }

    /// Sequential reconfigures per rung and issues one request per frame, so
    /// there is no bracket boundary to pay for.
    func testSequentialHasNoSeamsAtAll() {
        let e = SessionEstimate.forShotList([entry(frames: 64, firing: .sequential)],
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

/// Firing mode is part of the recipe, because the two modes do not produce the
/// same record: sequential asks the device what it achieved after each frame,
/// and a burst cannot. A name that could mean either does not reproduce.
final class FiringModeTests: XCTestCase {

    private func set(_ frames: Int, firing: ExecutionMode?) -> CaptureSet {
        var s = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.004, iso: 100),
                                    count: frames, name: "ladder")
        s.executionMode = firing
        return s
    }

    private func entry(_ frames: Int, firing: ExecutionMode?) -> ShotListEntry {
        ShotListEntry(index: 0, sensor: .wide, captureSet: set(frames, firing: firing))
    }

    /// Protocols written before firing joined the recipe have no value stored.
    /// They read as burst — what 29 of the first 31 real brackets used.
    func testAProtocolSavedBeforeThisExistedReadsAsBurst() {
        XCTAssertEqual(set(4, firing: nil).firing, .hardwareBracket)
    }

    func testFiringSurvivesASaveAndReload() throws {
        let stored = set(4, firing: .sequential)
        let round = try JSONDecoder().decode(
            CaptureSet.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(round.firing, .sequential,
                       "a recipe that does not carry its firing mode does not reproduce")
    }

    /// The stored tokens are load-bearing: 25 stations already on disk use them,
    /// and only the labels changed.
    func testTheStoredTokensDidNotChangeWhenTheLabelsDid() {
        XCTAssertEqual(ExecutionMode.hardwareBracket.rawValue, "hardwareBracket")
        XCTAssertEqual(ExecutionMode.sequential.rawValue, "sequential")
        XCTAssertEqual(ExecutionMode.hardwareBracket.label, "Burst")
        XCTAssertEqual(ExecutionMode.sequential.label, "Sequential")
    }

    /// A shot list may now mix modes, so the estimate has to read each entry
    /// rather than apply one global setting to all of them.
    func testAMixedShotListIsEstimatedPerEntry() {
        let mixed = SessionEstimate.forShotList(
            [entry(8, firing: .hardwareBracket), entry(8, firing: .sequential)],
            minimumGap: 0, includeStillness: false)
        let allBurst = SessionEstimate.forShotList(
            [entry(8, firing: .hardwareBracket), entry(8, firing: .hardwareBracket)],
            minimumGap: 0, includeStillness: false)
        XCTAssertGreaterThan(mixed.typicalSeconds, allBurst.typicalSeconds,
                             "the sequential half must cost more than a burst half")
    }

    /// A burst is one hardware request with nowhere to insert a wait, so
    /// charging for a gap predicted time the app was never going to spend.
    func testAGapIsNotChargedToABurstThatCannotHonourIt() {
        let withGap = SessionEstimate.forShotList([entry(8, firing: .hardwareBracket)],
                                                  minimumGap: 1.0, includeStillness: false)
        let without = SessionEstimate.forShotList([entry(8, firing: .hardwareBracket)],
                                                  minimumGap: 0, includeStillness: false)
        XCTAssertEqual(withGap.typicalSeconds, without.typicalSeconds, accuracy: 1e-9)
    }

    func testAGapIsChargedToASequentialSetThatCanHonourIt() {
        let withGap = SessionEstimate.forShotList([entry(8, firing: .sequential)],
                                                  minimumGap: 1.0, includeStillness: false)
        let without = SessionEstimate.forShotList([entry(8, firing: .sequential)],
                                                  minimumGap: 0, includeStillness: false)
        XCTAssertEqual(withGap.typicalSeconds - without.typicalSeconds, 8.0, accuracy: 1e-9)
    }
}

/// Drawing a station against a clock.
///
/// The parts are tested rather than the pixels: where the time goes, what steps
/// the shot list implies, and the one place the drawing departs from the clock.
final class TimelineTests: XCTestCase {

    private func entry(_ sensor: SensorCapability.Sensor, frames: Int,
                       firing: ExecutionMode = .hardwareBracket) -> ShotListEntry {
        var set = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.004, iso: 100),
                                      count: frames, name: "ladder")
        set.executionMode = firing
        return ShotListEntry(index: 0, sensor: sensor, captureSet: set)
    }

    // MARK: - Where the time goes

    func testTheBreakdownAccountsForEveryPartOfTheEstimate() {
        let e = SessionEstimate.forShotList(
            [entry(.wide, frames: 8), entry(.telephoto, frames: 16)],
            minimumGap: 0, bracketCeiling: 8, profile: .reference)
        XCTAssertEqual(e.breakdown.total, e.worstCaseSeconds, accuracy: 1e-9,
                       "a part unaccounted for would draw a bar that does not add up")
    }

    /// The headline a plan should deliver without being read.
    func testMostOfATwoSensorStationIsNotShooting() {
        let e = SessionEstimate.forShotList(
            [entry(.wide, frames: 4), entry(.telephoto, frames: 4)],
            minimumGap: 0, bracketCeiling: 8, profile: .reference)
        XCTAssertGreaterThan(e.breakdown.notShooting, 0.9,
                             "two swaps and two settles dwarf eight short exposures")
    }

    /// The flow calls `configure` and waits for the session on **every** set,
    /// so charging it per sensor change under-estimated every multi-set station
    /// — maximally on a phone with one rear camera, where no set ever changes
    /// sensor.
    func testSetupIsChargedPerSetNotPerSensorChange() {
        let three = SessionEstimate.forShotList(
            [entry(.wide, frames: 1), entry(.wide, frames: 1), entry(.wide, frames: 1)],
            minimumGap: 0, includeStillness: false, bracketCeiling: 8, profile: .reference)
        XCTAssertEqual(three.breakdown.setup,
                       3 * DeviceProfile.reference.sensorSwap.value, accuracy: 1e-9,
                       "three sets on one sensor pay three configures")
        XCTAssertEqual(three.sensorSwaps, 1, "but they are still one sensor run")
    }

    /// The stillness wait runs per set too, for the same reason.
    func testSettlingIsChargedPerSetNotPerSensorChange() {
        let two = SessionEstimate.forShotList(
            [entry(.wide, frames: 1), entry(.wide, frames: 1)],
            minimumGap: 0, bracketCeiling: 8, profile: .reference)
        XCTAssertEqual(two.breakdown.settles,
                       2 * DeviceProfile.reference.stillnessTimeout.value, accuracy: 1e-9)
    }

    /// A one-sensor phone is the case this correction matters most for: nothing
    /// about its station is a "swap", yet every set still pays a setup.
    func testASingleSensorStationStillPaysSetupForEverySet() {
        let e = SessionEstimate.forShotList(
            [entry(.wide, frames: 4), entry(.wide, frames: 4)],
            minimumGap: 0, includeStillness: false, bracketCeiling: 8, profile: .reference)
        XCTAssertEqual(e.sensorSwaps, 1, "one sensor, one run")
        XCTAssertGreaterThan(e.breakdown.setup, DeviceProfile.reference.sensorSwap.value,
                             "yet more than one setup is paid for")
        XCTAssertEqual(e.breakdown.seams, 0)
    }

    func testSeamsAppearOnlyWhenASetOutgrowsOneRequest() {
        let short = SessionEstimate.forShotList([entry(.wide, frames: 8)],
                                                minimumGap: 0, bracketCeiling: 8, profile: .reference)
        let long = SessionEstimate.forShotList([entry(.wide, frames: 16)],
                                               minimumGap: 0, bracketCeiling: 8, profile: .reference)
        XCTAssertEqual(short.breakdown.seams, 0)
        XCTAssertEqual(long.breakdown.seams, DeviceProfile.reference.bracketSeam.value, accuracy: 1e-9)
    }

    // MARK: - The steps a shot list implies

    /// Consecutive sets on one sensor do **not** share a setup. This test used
    /// to assert that they did, which was the bug: the flow calls `configure`
    /// and waits for stillness on every set, so the timeline must draw them
    /// every time or it would show a station shorter than the one that runs.
    func testEverySetGetsItsOwnSetupAndSettleEvenOnOneSensor() {
        let steps = StationTimeline.steps(
            entries: [entry(.wide, frames: 4), entry(.wide, frames: 4),
                      entry(.telephoto, frames: 4)],
            minimumGap: 0, bracketCeiling: 8)
        XCTAssertEqual(steps.filter { $0.kind == .swap }.count, 3)
        XCTAssertEqual(steps.filter { $0.kind == .settle }.count, 3)
        XCTAssertEqual(steps.filter { $0.kind == .set }.count, 3)
    }

    /// Preparation, graph reuse and a real sensor swap are different events;
    /// the plan must name them honestly instead of calling the first one a swap.
    func testASetupDistinguishesPreparationReuseAndASensorSwap() {
        let steps = StationTimeline.steps(
            entries: [entry(.wide, frames: 4), entry(.wide, frames: 4),
                      entry(.telephoto, frames: 4)],
            minimumGap: 0, bracketCeiling: 8)
        let titles = steps.filter { $0.kind == .swap }.map(\.title)
        XCTAssertEqual(titles, ["Prepare 1x", "Reuse 1x", "Swap to tele"])
    }

    func testASetStepCarriesItsLadderShape() {
        var sweep = CaptureSet.shutterSweep(
            base: CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100), stopsPerRung: 1, rungs: 5)
        sweep.executionMode = .hardwareBracket
        let steps = StationTimeline.steps(
            entries: [ShotListEntry(index: 0, sensor: .wide, captureSet: sweep)],
            minimumGap: 0, bracketCeiling: 8)
        let rungs = steps.first { $0.kind == .set }?.rungs ?? []
        XCTAssertEqual(rungs.count, 5)
        // Normalised against the longest rung, so the ladder's shape is visible.
        XCTAssertEqual(rungs.max() ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(rungs.first ?? 1, 0.1, "a five-rung one-stop sweep spans 16x")
    }

    // MARK: - The one place the drawing departs from the clock

    /// Duration is a bar rather than a block height, because a block has to
    /// hold a title and a caption and so cannot go below about 130 points —
    /// which made a 264 ms set and a 3.8 s set the same size while the view
    /// claimed to be to scale. A bar has no such floor.
    func testTheBarIsExactAcrossA450To1Ratio() {
        XCTAssertEqual(StationTimeline.barFraction(0.033, longest: 14.9), 0.00221, accuracy: 1e-5)
        XCTAssertEqual(StationTimeline.barFraction(14.9, longest: 14.9), 1.0, accuracy: 1e-9)
    }

    func testTheBarIsLinearInBetween() {
        XCTAssertEqual(StationTimeline.barFraction(5, longest: 10), 0.5, accuracy: 1e-9)
    }

    func testAnEmptyOrZeroLengthPlanDoesNotDivideByZero() {
        XCTAssertEqual(StationTimeline.barFraction(0, longest: 0), 0)
        XCTAssertEqual(StationTimeline.barFraction(1, longest: 0), 0)
    }

    /// Nothing is allowed to draw past the end of its track.
    func testABarNeverExceedsItsTrack() {
        XCTAssertEqual(StationTimeline.barFraction(20, longest: 10), 1.0)
    }
}
