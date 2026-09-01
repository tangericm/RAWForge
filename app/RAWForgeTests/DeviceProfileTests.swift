import XCTest
@testable import RAWForge

/// The honesty machinery around device timings.
///
/// The capture side of characterisation needs a sensor and is covered in
/// `DeviceCaptureTests`. Everything here — provenance, storage, what the
/// estimate does with a profile, and the arithmetic the run depends on — is
/// device-independent and runs anywhere.
final class DeviceProfileTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeviceProfile.forget()
    }

    override func tearDown() {
        DeviceProfile.forget()
        super.tearDown()
    }

    // MARK: - Provenance

    func testTheReferenceProfileIsEntirelyBorrowed() {
        let r = DeviceProfile.reference
        XCTAssertEqual(r.borrowedCount, r.readings.count,
                       "nothing in the reference was measured on the device in hand")
        XCTAssertFalse(r.isCharacterised)
        XCTAssertNil(r.measuredAt)
    }

    func testWithoutAStoredProfileTheAppFallsBackToTheReference() {
        XCTAssertEqual(DeviceProfile.active, DeviceProfile.reference)
        XCTAssertFalse(DeviceProfile.active.isCharacterised)
    }

    /// The interface distinguishes measured from borrowed by this flag alone,
    /// so it has to survive a round trip through disk.
    func testProvenanceSurvivesBeingSavedAndReloaded() throws {
        let measured = Self.characterised(model: DeviceIdentity.current().modelIdentifier)
        try measured.save()
        DeviceProfile.forget()   // clears the cache, leaves nothing on disk
        try measured.save()

        let loaded = DeviceProfile.active
        XCTAssertTrue(loaded.isCharacterised)
        XCTAssertTrue(loaded.sensorFramePeriod.isMeasured)
        XCTAssertEqual(loaded.sensorFramePeriod.sampleCount, 7)
        XCTAssertFalse(loaded.stillnessTimeout.isMeasured,
                       "the settle is not a property of the phone and must stay borrowed")
    }

    /// Profiles already on disk predate the reuse measurement. They must keep
    /// decoding, and the estimate must fall back conservatively to the measured
    /// swap rather than inventing a zero-cost operation.
    func testALegacyProfileBorrowsItsSameSensorCostFromTheSwap() throws {
        let legacy = DeviceProfile.reference
        let round = try JSONDecoder.rawforge.decode(
            DeviceProfile.self, from: JSONEncoder.rawforge.encode(legacy))
        let reuse = try XCTUnwrap(round.readings.first { $0.name == "Same-sensor setup" }?.reading)

        XCTAssertFalse(reuse.isMeasured)
        XCTAssertEqual(reuse.value, round.sensorSwap.value, accuracy: 1e-9)
        XCTAssertFalse(round.isCharacterised,
                       "a legacy profile must invite one re-measurement for the new timing")
    }

    /// A measured value cannot be merely accepted by the decoder and then
    /// dropped. `readings` is what the Bench and provenance count consume, so
    /// finding it there proves the value survives into the app's public model.
    func testAMeasuredSameSensorCostSurvivesDecoding() throws {
        let measured = Reading.measured(0.007, samples: 7, spread: 0.001)
        let profile = try Self.profileWithSameSensorSetup(measured)
        let reuse = try XCTUnwrap(profile.readings.first {
            $0.name == "Same-sensor setup"
        }?.reading)

        XCTAssertEqual(reuse, measured)
    }

    /// The failure this guard exists for: a backup restored onto different
    /// hardware would otherwise apply one phone's timings to another silently.
    func testAProfileFromAnotherDeviceIsDiscardedRatherThanApplied() throws {
        let foreign = Self.characterised(model: "iPhone99,9")
        try foreign.save()
        DeviceProfile.forget()
        try JSONEncoder.rawforge.encode(foreign).write(to: DeviceProfile.fileURL)

        XCTAssertEqual(DeviceProfile.active, DeviceProfile.reference,
                       "a profile describing other hardware must not be trusted")
    }

    // MARK: - What the estimate does with it

    func testAMeasuredProfileChangesThePlanRatherThanJustTheLabel() {
        let entry = Self.entry(frames: 8)
        let borrowed = SessionEstimate.forShotList(
            [entry], minimumGap: 0,
            bracketCeiling: 8, profile: .reference)

        // A phone twice as slow per frame should produce a visibly longer plan.
        var slow = DeviceProfile.reference
        slow = Self.with(slow, framePeriod: .measured(0.0668, samples: 7, spread: 0.001))
        let measured = SessionEstimate.forShotList(
            [entry], minimumGap: 0,
            bracketCeiling: 8, profile: slow)

        XCTAssertGreaterThan(measured.typicalSeconds, borrowed.typicalSeconds,
                             "the plan must follow the profile, not a constant")
        XCTAssertEqual(measured.typicalSeconds - borrowed.typicalSeconds,
                       8 * (0.0668 - 0.0334), accuracy: 1e-6)
    }

    func testStorageFiguresComeFromTheProfileToo() {
        var fat = DeviceProfile.reference
        fat.worstCaseFrameBytes = .measured(60_000_000, samples: 20, spread: 0)
        let e = SessionEstimate.forShotList([Self.entry(frames: 10)], 
                                           minimumGap: 0, profile: fat)
        XCTAssertEqual(e.worstCaseBytes, 600_000_000)
    }

    func testAnEstimateCarriesTheProfileItWasBuiltFrom() {
        let e = SessionEstimate.forShotList([Self.entry(frames: 3)], 
                                           minimumGap: 0, profile: .reference)
        XCTAssertFalse(e.profile.isCharacterised,
                       "the plan screen decides whether to warn from this")
    }

    /// The first set may need a real setup. Consecutive sets on its already-live
    /// sensor pay the separately measured reuse cost, not another sensor swap.
    func testConsecutiveSetsUseTheMeasuredReuseCost() throws {
        let profile = try Self.profileWithSameSensorSetup(
            .measured(0.007, samples: 7, spread: 0.001))
        let entries = [Self.entry(frames: 1), Self.entry(frames: 1), Self.entry(frames: 1)]
        let estimate = SessionEstimate.forShotList(
            entries, minimumGap: 0, includeStillness: false,
            bracketCeiling: 8, profile: profile)

        XCTAssertEqual(estimate.breakdown.setup, 0.40 + 0.007 + 0.007,
                       accuracy: 1e-9)
    }

    // MARK: - Learning the worst case from real work

    /// A characterisation run measures whatever the lens happened to see, which
    /// is a floor. The ceiling is learned from actual captures.
    func testALargerFrameRaisesTheWorstCaseAndSmallerOnesDoNot() throws {
        try Self.characterised(model: DeviceIdentity.current().modelIdentifier).save()
        let before = DeviceProfile.active.worstCaseFrameBytes.value

        DeviceProfile.noteObservedFrame(bytes: Int(before) - 1_000_000)
        XCTAssertEqual(DeviceProfile.active.worstCaseFrameBytes.value, before,
                       "a smaller frame says nothing about the worst case")

        DeviceProfile.noteObservedFrame(bytes: Int(before) + 5_000_000)
        XCTAssertEqual(DeviceProfile.active.worstCaseFrameBytes.value, before + 5_000_000)
        XCTAssertTrue(DeviceProfile.active.worstCaseFrameBytes.isMeasured)
    }

    // MARK: - The run's arithmetic

    func testGapsAreDifferencesBetweenSuccessiveTimestamps() {
        let gaps = DeviceCharacterisation.differences([10.0, 10.1, 10.25, 10.3])
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0], 0.1, accuracy: 1e-9)
        XCTAssertEqual(gaps[1], 0.15, accuracy: 1e-9)
        XCTAssertEqual(DeviceCharacterisation.differences([1.0]), [])
    }

    /// Median rather than mean, so one frame delayed by something unrelated
    /// cannot move a figure the whole plan rests on.
    func testMedianIgnoresASingleOutlierThatWouldMoveAMean() {
        let clean = [0.033, 0.034, 0.033, 0.034, 0.033]
        let withStall = clean + [2.0]
        XCTAssertEqual(DeviceCharacterisation.median(clean), 0.033, accuracy: 1e-9)
        XCTAssertLessThan(DeviceCharacterisation.median(withStall), 0.04,
                          "a 2 s stall must not drag the frame period with it")
        let mean = withStall.reduce(0, +) / Double(withStall.count)
        XCTAssertGreaterThan(mean, 0.3, "which is exactly what a mean would have done")
    }

    func testSpreadReportsTheRangeSoAWideResultCanBeDistrusted() {
        XCTAssertEqual(DeviceCharacterisation.spread([0.03, 0.05, 0.04]), 0.02, accuracy: 1e-9)
        XCTAssertEqual(DeviceCharacterisation.spread([]), 0)
    }

    // MARK: - Sessions

    func testASessionRecordsTheProfileItWasPlannedAgainst() throws {
        let report = CapabilityReport(device: DeviceIdentity.current(), sensors: [])
        let session = SessionRecord(sessionId: "test", openedAt: Date(),
                                    openedAtUptime: 0, capability: report,
                                    availableCapacityBytes: nil)
        let round = try JSONDecoder.rawforge.decode(
            SessionRecord.self, from: JSONEncoder.rawforge.encode(session))
        XCTAssertNotNil(round.deviceProfile,
                        "a reader holding only the session must be able to tell what the plan rested on")
        XCTAssertEqual(round.deviceProfile?.modelIdentifier,
                       DeviceProfile.active.modelIdentifier)
    }

    // MARK: - Fixtures

    private static func entry(frames: Int) -> ShotListEntry {
        var set = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.001, iso: 100),
                                      count: frames, name: "r")
        set.executionMode = .hardwareBracket
        return ShotListEntry(index: 0, sensor: .wide, captureSet: set)
    }

    private static func with(_ p: DeviceProfile, framePeriod: Reading) -> DeviceProfile {
        DeviceProfile(modelIdentifier: p.modelIdentifier, systemVersion: p.systemVersion,
                      appVersion: p.appVersion, measuredAt: p.measuredAt,
                      sensorFramePeriod: framePeriod,
                      sequentialOverheadPerFrame: p.sequentialOverheadPerFrame,
                      sensorSwap: p.sensorSwap, sameSensorSetup: p.sameSensorSetup,
                      bracketSeam: p.bracketSeam,
                      averageFrameBytes: p.averageFrameBytes,
                      worstCaseFrameBytes: p.worstCaseFrameBytes,
                      stillnessTimeout: p.stillnessTimeout)
    }

    private static func characterised(model: String) -> DeviceProfile {
        DeviceProfile(
            modelIdentifier: model, systemVersion: "26.0", appVersion: "test",
            measuredAt: Date(),
            sensorFramePeriod: .measured(0.0334, samples: 7, spread: 0.002),
            sequentialOverheadPerFrame: .measured(0.233, samples: 5, spread: 0.05),
            sensorSwap: .measured(0.40, samples: 3, spread: 0.06),
            sameSensorSetup: .measured(0.007, samples: 7, spread: 0.001),
            bracketSeam: .measured(0.567, samples: 1, spread: 0),
            averageFrameBytes: .measured(10_000_000, samples: 20, spread: 2_000_000),
            worstCaseFrameBytes: .measured(12_000_000, samples: 20, spread: 0),
            stillnessTimeout: DeviceProfile.reference.stillnessTimeout)
    }

    /// Injects the new field at the serialized boundary. This keeps the tests
    /// compileable before the model grows the field, so RED is a behavioral
    /// failure rather than a missing-member compiler error.
    private static func profileWithSameSensorSetup(_ reading: Reading) throws -> DeviceProfile {
        let encoded = try JSONEncoder.rawforge.encode(DeviceProfile.reference)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["sameSensorSetup"] = try JSONSerialization.jsonObject(
            with: JSONEncoder.rawforge.encode(reading))
        return try JSONDecoder.rawforge.decode(
            DeviceProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
