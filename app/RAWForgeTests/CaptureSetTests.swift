import XCTest
@testable import RAWForge

/// Tests for the parts that decide what gets shot. These are the places where a
/// silent error produces frames that look fine and are wrong, which is the
/// failure mode this whole project exists to prevent.
final class CaptureSetTests: XCTestCase {

    private func sensor(minISO: Float = 55, maxISO: Float = 12320,
                        minExp: Double = 1.5e-05, maxExp: Double = 1.0) -> SensorCapability {
        SensorCapability(
            sensor: .wide, localizedName: "Back Camera", uniqueID: "u", modelID: "m",
            bayerFormat: 1650943796, allRawFormats: [], rawFormatsRequiredRunningSession: false,
            exclusionReason: nil, supportsCustomExposure: true,
            supportsWhiteBalanceCustomGainLock: true,
            supportsLockedFocus: true, supportsCustomLensPosition: true,
            supportsFocusPointOfInterest: true,
            minimumFocusDistanceMillimetres: 120, horizontalFieldOfViewDegrees: 69,
            maxBracketedCapturePhotoCount: 8,
            maxWhiteBalanceGain: 4, minAvailableVideoZoomFactor: 1,
            minISO: minISO, maxISO: maxISO,
            minExposureSeconds: minExp, maxExposureSeconds: maxExp)
    }

    func testSweepIsCentredOnTheAuthoredRung() {
        let base = CaptureSpec(shutterSeconds: 1.0 / 8, iso: 100)
        let set = CaptureSet.shutterSweep(base: base, stopsPerRung: 1, rungs: 7)
        XCTAssertEqual(set.specs.count, 7)
        // Odd rung count must contain the base exactly — the authored value is
        // the one the operator expects to have shot.
        XCTAssertEqual(set.specs[3].shutterSeconds, 1.0 / 8, accuracy: 1e-12)
        XCTAssertEqual(set.specs.first!.shutterSeconds, 1.0 / 64, accuracy: 1e-12)
        XCTAssertEqual(set.specs.last!.shutterSeconds, 1.0, accuracy: 1e-12)
    }

    func testSweepSpacingIsGeometricInStops() {
        let set = CaptureSet.shutterSweep(
            base: CaptureSpec(shutterSeconds: 1.0 / 60, iso: 100), stopsPerRung: 1, rungs: 6)
        for i in 1..<set.specs.count {
            let ratio = set.specs[i].shutterSeconds / set.specs[i - 1].shutterSeconds
            XCTAssertEqual(ratio, 2.0, accuracy: 1e-9, "rung \(i) is not one stop from its neighbour")
        }
    }

    /// #8: rails are validated at authoring time and out-of-range rungs are
    /// dropped and recorded, never clamped. A clamped rung captures at a value
    /// nobody asked for and reads back as though it were the request.
    func testOutOfRailRungsAreDroppedNotClamped() {
        let set = CaptureSet.shutterSweep(
            base: CaptureSpec(shutterSeconds: 1.0 / 8, iso: 100), stopsPerRung: 1, rungs: 8)
        let checked = set.validated(against: sensor())
        XCTAssertEqual(checked.kept.count + checked.dropped.count, 8)
        XCTAssertEqual(checked.dropped.count, 1, "the 1.414 s rung is past the 1 s ceiling")
        XCTAssertTrue(checked.dropped[0].reason.contains("ceiling"))
        // Nothing kept may sit outside the rails.
        for s in checked.kept {
            XCTAssertLessThanOrEqual(s.shutterSeconds, 1.0)
            XCTAssertGreaterThanOrEqual(s.shutterSeconds, 1.5e-05)
        }
        // And no kept rung equals the ceiling by having been clamped to it.
        XCTAssertFalse(checked.kept.contains { $0.shutterSeconds == 1.0 && $0.shutterSeconds != set.specs.last?.shutterSeconds })
    }

    /// The boundary matters: 1 s is exactly `maxExposureDuration`, and a
    /// half-open comparison would silently drop the most useful dark rung.
    func testExactBoundaryRungIsKept() {
        let set = CaptureSet(name: "edge", version: 1,
                             specs: [CaptureSpec(shutterSeconds: 1.0, iso: 55)],
                             generator: .manual, perSensorEVOffsetStops: [:])
        XCTAssertEqual(set.validated(against: sensor()).kept.count, 1)
        XCTAssertEqual(set.validated(against: sensor()).dropped.count, 0)
    }

    func testISORailsAreEnforcedSeparately() {
        let set = CaptureSet.repeated(CaptureSpec(shutterSeconds: 1.0 / 60, iso: 20), count: 3)
        let checked = set.validated(against: sensor(minISO: 55))
        XCTAssertEqual(checked.kept.count, 0)
        XCTAssertEqual(checked.dropped.count, 3)
        XCTAssertTrue(checked.dropped[0].reason.contains("ISO"))
    }

    /// #8: one definition across sensors with a per-sensor EV offset, storing
    /// both canonical and rendered.
    func testEVOffsetRendersWithoutMutatingTheDefinition() {
        let base = CaptureSet.repeated(CaptureSpec(shutterSeconds: 1.0 / 100, iso: 100), count: 2)
        let set = CaptureSet(name: base.name, version: base.version, specs: base.specs,
                             generator: base.generator,
                             perSensorEVOffsetStops: ["tele": 1.0])
        XCTAssertEqual(set.rendered(for: .wide)[0].shutterSeconds, 1.0 / 100, accuracy: 1e-12)
        XCTAssertEqual(set.rendered(for: .telephoto)[0].shutterSeconds, 1.0 / 50, accuracy: 1e-12)
        XCTAssertEqual(set.specs[0].shutterSeconds, 1.0 / 100, accuracy: 1e-12,
                       "rendering must not mutate the canonical definition")
    }

    func testRepeatSetIsIdenticalRungs() {
        let spec = CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100)
        let set = CaptureSet.repeated(spec, count: 16)
        XCTAssertEqual(set.specs.count, 16)
        XCTAssertTrue(set.specs.allSatisfy { $0 == spec })
    }
}
