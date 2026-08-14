import CoreGraphics
import XCTest
@testable import RAWForge

/// What the app claims about focus, tested where the claims actually live.
///
/// Almost none of #18 needs a camera. Whether a lens position may be carried to
/// another sensor, where a tapped point lands after a swap, and what a station
/// restores when it comes back to a sensor are all decisions, not measurements —
/// and they are the decisions that would silently corrupt a log if they were
/// wrong. The hardware part (does `setFocusModeLocked` actually hold?) is left
/// to a device run, and is deliberately the smaller half.
final class FocusGeometryTests: XCTestCase {

    // MARK: - The scale factor

    /// Mapping from a wide field of view into a narrow one spreads points
    /// apart, because the narrow sensor sees a crop of what the wide one saw.
    /// If this ever came out below 1 the mapping would be inverted, and an
    /// off-centre tap would map *inward* — plausible-looking and wrong.
    func testMappingFromAWiderSensorToANarrowerOneSpreadsPointsApart() {
        let k = FocusGeometry.scale(fromFieldOfView: 106, toFieldOfView: 69)
        XCTAssertNotNil(k)
        XCTAssertGreaterThan(k!, 1)
    }

    func testMappingFromANarrowerSensorToAWiderOnePullsPointsIn() {
        let k = FocusGeometry.scale(fromFieldOfView: 69, toFieldOfView: 106)
        XCTAssertNotNil(k)
        XCTAssertLessThan(k!, 1)
    }

    func testTheScaleBetweenASensorAndItselfIsExactlyOne() {
        XCTAssertEqual(FocusGeometry.scale(fromFieldOfView: 69, toFieldOfView: 69)!,
                       1, accuracy: 1e-12)
    }

    /// A field of view of zero is absence, not a camera that sees nothing, and
    /// 180° or more is not a rectilinear frame at all — both would produce a
    /// scale factor that silently poisons every mapping made with it.
    func testAnImpossibleFieldOfViewYieldsNoScaleRatherThanABadOne() {
        XCTAssertNil(FocusGeometry.scale(fromFieldOfView: 0, toFieldOfView: 69))
        XCTAssertNil(FocusGeometry.scale(fromFieldOfView: 69, toFieldOfView: 0))
        XCTAssertNil(FocusGeometry.scale(fromFieldOfView: 180, toFieldOfView: 69))
        XCTAssertNil(FocusGeometry.scale(fromFieldOfView: -10, toFieldOfView: 69))
    }

    // MARK: - Mapping a point

    func testTheCentreOfTheFrameMapsToTheCentreWhateverTheSensors() {
        for (from, to) in [(106.0, 69.0), (69.0, 25.0), (25.0, 106.0)] {
            let m = FocusGeometry.map(point: CGPoint(x: 0.5, y: 0.5),
                                      fromFieldOfView: from, toFieldOfView: to)
            guard let p = m.usablePoint else { return XCTFail("centre must always map") }
            XCTAssertEqual(p.x, 0.5, accuracy: 1e-12)
            XCTAssertEqual(p.y, 0.5, accuracy: 1e-12)
        }
    }

    /// The reason the return type is not just a `CGPoint`. An ultra-wide sees
    /// far more than the wide, so most of its frame has no counterpart — and
    /// clamping such a point to the frame edge would aim autofocus at something
    /// the operator never chose while reporting success.
    func testAPointOutsideTheDestinationSensorsViewIsReportedNotClamped() {
        let m = FocusGeometry.map(point: CGPoint(x: 0.9, y: 0.5),
                                  fromFieldOfView: 106, toFieldOfView: 69)
        guard case let .outsideFrame(p) = m else {
            return XCTFail("an edge tap on the ultra-wide has no counterpart on the wide")
        }
        XCTAssertNil(m.usablePoint, "an unusable point must not read as a usable one")
        XCTAssertGreaterThan(p.x, 1, "the unclamped position says how far outside it fell")
    }

    /// The wide's whole frame is inside the ultra-wide's, so this direction can
    /// never fail — which is worth pinning, because it is the direction the
    /// pre-flight will most often seed from.
    func testEveryPointOnTheNarrowSensorHasACounterpartOnTheWiderOne() {
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            let m = FocusGeometry.map(point: CGPoint(x: u, y: u),
                                      fromFieldOfView: 69, toFieldOfView: 106)
            XCTAssertNotNil(m.usablePoint, "\(u) should map from the wide into the ultra-wide")
        }
    }

    /// The point has to be inside *both* frames for a round trip to mean
    /// anything. The wide-to-telephoto scale is about 3.1, so this sits well
    /// inside the tele's frame — an earlier version of this test used a point
    /// that mapped off the top edge, which is the failure the assertion below
    /// would otherwise have hidden behind a nil.
    func testMappingThereAndBackReturnsTheOriginalPoint() {
        let start = CGPoint(x: 0.55, y: 0.47)
        guard let there = FocusGeometry.map(point: start, fromFieldOfView: 69,
                                            toFieldOfView: 25).usablePoint,
              let back = FocusGeometry.map(point: there, fromFieldOfView: 25,
                                           toFieldOfView: 69).usablePoint else {
            return XCTFail("a point inside both frames must survive the round trip")
        }
        XCTAssertEqual(back.x, start.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, start.y, accuracy: 1e-9)
    }

    /// The mapping applies one factor to both axes, which is exact only because
    /// the sensors share an aspect ratio. If that ever stops holding the
    /// vertical would need its own scale — this test is where that shows up.
    func testBothAxesUseTheSameScale() {
        let m = FocusGeometry.map(point: CGPoint(x: 0.7, y: 0.3),
                                  fromFieldOfView: 69, toFieldOfView: 106)
        guard let p = m.usablePoint else { return XCTFail("should be inside") }
        XCTAssertEqual(p.x - 0.5, -(p.y - 0.5), accuracy: 1e-12,
                       "symmetric offsets must stay symmetric")
    }

    func testNoMappingIsAttemptedWhenAFieldOfViewIsUnknown() {
        XCTAssertEqual(FocusGeometry.map(point: CGPoint(x: 0.5, y: 0.5),
                                         fromFieldOfView: 0, toFieldOfView: 69), .unknown)
    }

    // MARK: - The error the mapping does not correct

    /// Parallax is the mapping's one real inaccuracy, and it is reported rather
    /// than corrected because correcting it needs the subject distance, which
    /// the app has no way to know. The numbers here are the ones quoted in the
    /// documentation — if they drift, the documentation is wrong.
    func testParallaxErrorIsSmallAtAMetreAndGrowsAsTheSubjectComesCloser() {
        let far = FocusGeometry.parallaxErrorDegrees(subjectDistanceMetres: 1)!
        let near = FocusGeometry.parallaxErrorDegrees(subjectDistanceMetres: 0.3)!
        XCTAssertEqual(far, 0.52, accuracy: 0.05)
        XCTAssertEqual(near, 1.72, accuracy: 0.1)
        XCTAssertGreaterThan(near, far)
    }

    func testParallaxIsUndefinedRatherThanInfiniteAtZeroDistance() {
        XCTAssertNil(FocusGeometry.parallaxErrorDegrees(subjectDistanceMetres: 0))
    }
}

/// The rules for what a station carries between its sets.
final class FocusContinuityTests: XCTestCase {

    private func focus(_ acquisition: String, lens: Float?) -> FrameRecord.Focus {
        FrameRecord.Focus(intent: "automatic", acquisition: acquisition, mode: "locked",
                          lensPosition: lens, pointOfInterest: nil,
                          pointMappedFromSensor: nil, converged: true,
                          acquisitionSeconds: 0.2, minimumFocusDistanceMillimetres: 120,
                          note: nil)
    }

    func testTheFirstSetOnASensorAcquiresFocusRatherThanRestoringIt() {
        let c = FocusContinuity()
        XCTAssertNil(c.resolution(for: .wide, plan: FocusPlan()).restore)
    }

    /// The rule the whole type exists for. Two sets on one sensor at one pose
    /// must be focused identically, and asking autofocus the same question
    /// twice is not a way to get the same answer twice.
    func testReturningToASensorRestoresItsOwnMeasurementExactly() {
        var c = FocusContinuity()
        c.record(focus("autofocused", lens: 0.6213), for: .wide)
        XCTAssertEqual(c.resolution(for: .wide, plan: FocusPlan()).restore, 0.6213)
    }

    /// The heart of it: a lens position is an actuator coordinate, so carrying
    /// the wide's 0.6213 to the ultra-wide would command a *different distance*
    /// while the log claimed continuity. The ultra-wide must acquire its own.
    func testALensPositionIsNeverCarriedToADifferentSensor() {
        var c = FocusContinuity()
        c.record(focus("autofocused", lens: 0.6213), for: .wide)
        XCTAssertNil(c.resolution(for: .ultraWide, plan: FocusPlan()).restore,
                     "0.62 on the wide is not 0.62 on the ultra-wide")
        XCTAssertNil(c.resolution(for: .telephoto, plan: FocusPlan()).restore)
    }

    /// Swapping away and back is still the same pose and the same sensor, so
    /// the third set here must match the first. Restoring only from the
    /// immediately preceding set would quietly re-hunt instead.
    func testASensorRevisitedAfterAnotherSensorStillRestores() {
        var c = FocusContinuity()
        c.record(focus("autofocused", lens: 0.5), for: .wide)
        c.record(focus("autofocused", lens: 0.8), for: .telephoto)
        XCTAssertEqual(c.resolution(for: .wide, plan: FocusPlan()).restore, 0.5)
        XCTAssertEqual(c.resolution(for: .telephoto, plan: FocusPlan()).restore, 0.8)
    }

    /// A position read off a lens that was never locked describes where it
    /// drifted to, not where it was put. Restoring it later would manufacture a
    /// continuity that never existed.
    func testAPositionFromAnUnlockedLensIsNotWorthRestoring() {
        var c = FocusContinuity()
        c.record(focus("notLocked", lens: 0.44), for: .wide)
        XCTAssertNil(c.resolution(for: .wide, plan: FocusPlan()).restore)
    }

    func testAFocusWithNoLensPositionIsNotBanked() {
        var c = FocusContinuity()
        c.record(focus("autofocused", lens: nil), for: .wide)
        XCTAssertNil(c.resolution(for: .wide, plan: FocusPlan()).restore)
    }

    /// A pose is the scope of a focus decision. The phone has moved between
    /// stations, so last station's lens positions describe a different scene.
    func testNothingCarriesFromOneStationToTheNext() {
        var c = FocusContinuity()
        c.record(focus("autofocused", lens: 0.5), for: .wide)
        c.reset()
        XCTAssertNil(c.resolution(for: .wide, plan: FocusPlan()).restore)
    }

    /// An authored lens position is already exact, so there is nothing to
    /// restore — and restoring over it would replace the operator's number with
    /// a measurement, which is the wrong way round.
    func testAManualPositionIsCommandedRatherThanRestored() {
        var c = FocusContinuity()
        c.record(focus("autofocused", lens: 0.5), for: .wide)
        var plan = FocusPlan()
        plan[.wide] = .manual(lensPosition: 0.9)
        let r = c.resolution(for: .wide, plan: plan)
        XCTAssertNil(r.restore)
        XCTAssertEqual(r.intent.lensPosition, 0.9)
    }

    func testAPointIntentIsPassedThroughToTheRig() {
        var plan = FocusPlan()
        plan[.ultraWide] = .point(x: 0.25, y: 0.75)
        let r = FocusContinuity().resolution(for: .ultraWide, plan: plan)
        XCTAssertEqual(r.point, CGPoint(x: 0.25, y: 0.75))
    }
}

/// The plan itself, and what absence means in it.
final class FocusPlanTests: XCTestCase {

    /// Absence is a real state: a sensor nobody focused runs autofocus and locks
    /// it, which is strictly more determinism than the app had before #18.
    func testASensorWithNoEntryIsAutomaticRatherThanUndefined() {
        XCTAssertEqual(FocusPlan()[.wide], .automatic)
        XCTAssertFalse(FocusPlan().isCustomised)
    }

    func testSettingASensorBackToAutomaticLeavesThePlanUncustomised() {
        var plan = FocusPlan()
        plan[.wide] = .manual(lensPosition: 0.4)
        XCTAssertTrue(plan.isCustomised)
        plan[.wide] = .automatic
        XCTAssertFalse(plan.isCustomised, "an entry equal to the default is not a customisation")
    }

    func testThePlanSurvivesACodableRoundTrip() throws {
        var plan = FocusPlan()
        plan[.wide] = .point(x: 0.3, y: 0.7)
        plan[.telephoto] = .manual(lensPosition: 0.85)
        let back = try JSONDecoder().decode(
            FocusPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(back, plan)
    }

    func testTheSummaryNamesWhichSensorsWereSet() {
        var plan = FocusPlan()
        XCTAssertEqual(plan.summary(for: [.wide, .ultraWide]), "automatic")
        plan[.wide] = .manual(lensPosition: 0.4)
        XCTAssertEqual(plan.summary(for: [.wide, .ultraWide]), "set on 1x")
        plan[.ultraWide] = .automatic
        XCTAssertEqual(plan.summary(for: [.wide, .ultraWide]), "set on 1x",
                       "an explicit automatic is still the default")
        plan[.ultraWide] = .point(x: 0.5, y: 0.5)
        XCTAssertEqual(plan.summary(for: [.wide, .ultraWide]), "set on all 2")
    }
}

/// Reading files written before focus existed.
final class FocusSchemaTests: XCTestCase {

    /// Every focus field on `SensorCapability` is optional for exactly this
    /// reason. Sessions are already on disk, and a schema change that makes the
    /// browser report them as unreadable destroys the record it was added to
    /// improve.
    func testASensorRecordedBeforeFocusWasProbedStillDecodes() throws {
        let old = """
        {"sensor":"1x","localizedName":"Back Camera","uniqueID":"x","modelID":"m",
         "bayerFormat":1650943796,"allRawFormats":["'bgg4' bayer"],
         "rawFormatsRequiredRunningSession":false,
         "supportsCustomExposure":true,"supportsWhiteBalanceCustomGainLock":true,
         "maxBracketedCapturePhotoCount":8,"maxWhiteBalanceGain":4,
         "minAvailableVideoZoomFactor":1}
        """.data(using: .utf8)!
        let cap = try JSONDecoder().decode(SensorCapability.self, from: old)
        XCTAssertTrue(cap.isUsable)
        XCTAssertFalse(cap.focusWasProbed,
                       "nil must read as 'never asked', not as 'the sensor said no'")
        XCTAssertFalse(cap.canHoldFocus)
    }

    /// The same distinction, stated the other way: a sensor that was probed and
    /// answered no is not the same record as one that was never probed, and the
    /// app must not collapse them.
    func testASensorProbedAndUnableToLockIsDistinctFromOneNeverProbed() {
        let unable = SensorCapability.absent(.telephoto)
        XCTAssertTrue(unable.focusWasProbed)
        XCTAssertFalse(unable.canHoldFocus)
    }

    func testAFrameRecordedBeforeFocusExistedStillDecodes() throws {
        let old = """
        {"frameIndex":1,"filename":"f.dng","sensor":"1x",
         "requested":{"shutterSeconds":0.01,"iso":100},
         "dng":{},"capturedAtUptime":12.0,"capturedAt":760000000}
        """.data(using: .utf8)!
        let frame = try JSONDecoder().decode(FrameRecord.self, from: old)
        XCTAssertNil(frame.focus, "no focus record is not a claim that focus was unlocked")
    }

    func testAnUnlockedLensIsVisibleAsSuchInTheRecord() {
        let held = FrameRecord.Focus(
            intent: "automatic", acquisition: "autofocused", mode: "locked",
            lensPosition: 0.5, pointOfInterest: nil, pointMappedFromSensor: nil,
            converged: true, acquisitionSeconds: 0.1,
            minimumFocusDistanceMillimetres: 120, note: nil)
        let drifting = FrameRecord.Focus(
            intent: "automatic", acquisition: "notLocked", mode: "continuousAutoFocus",
            lensPosition: 0.5, pointOfInterest: nil, pointMappedFromSensor: nil,
            converged: nil, acquisitionSeconds: 0.1,
            minimumFocusDistanceMillimetres: 120,
            note: "this sensor cannot hold focus — it may drift across the set")
        XCTAssertTrue(held.wasHeld)
        XCTAssertFalse(drifting.wasHeld)
        XCTAssertNotNil(drifting.note, "an unheld lens must say why in the file itself")
    }
}
