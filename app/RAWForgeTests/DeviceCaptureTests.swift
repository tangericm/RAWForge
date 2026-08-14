import AVFoundation
import XCTest
@testable import RAWForge

/// The tests that need a real sensor.
///
/// Everything else in this suite runs on a simulator, which has no camera and
/// therefore cannot answer the questions that actually matter: does the rig
/// configure, does the exposure lock hold, does a capture return a Bayer DNG,
/// and does the viewfinder come back up after a set. Those are hardware facts
/// and this is where they get checked.
///
/// Every test skips rather than fails when there is no Bayer sensor, so the
/// suite stays green on a simulator instead of being noise there.
final class DeviceCaptureTests: XCTestCase {

    private var report: CapabilityReport!
    private var rig: CaptureRig!

    override func setUpWithError() throws {
        report = CapabilityProbe.run()
        try XCTSkipUnless(report.canCapture, "no Bayer sensor — device-only test")
        rig = CaptureRig()
    }

    override func tearDown() {
        rig?.stopSession()
        rig = nil
    }

    private var firstSensor: SensorCapability { report.usableSensors[0] }

    // MARK: - Configuring

    func testEveryUsableSensorConfiguresAndOffersBayer() async throws {
        for cap in report.usableSensors {
            try await rig.configure(cap.sensor)
            XCTAssertEqual(rig.sensor, cap.sensor)
            XCTAssertTrue(AVCapturePhotoOutput.isBayerRAWPixelFormat(rig.bayerFormat),
                          "\(cap.sensor.rawValue) configured to a non-Bayer format")
        }
    }

    /// A Bayer capture at any zoom factor other than 1.0 terminates the process
    /// rather than returning an error, so this is the invariant the whole
    /// capture path rests on. If configuring ever leaves zoom elsewhere, every
    /// capture becomes a crash.
    func testConfiguringLeavesZoomAtExactlyOne() async throws {
        for cap in report.usableSensors {
            try await rig.configure(cap.sensor)
            XCTAssertEqual(rig.currentZoomFactor, 1.0, accuracy: 0.0001,
                           "\(cap.sensor.rawValue) came up at a zoom factor that would "
                           + "kill the process on capture")
        }
    }

    // MARK: - The viewfinder lifecycle

    /// The failure I most expected on hardware: the preview goes down while a
    /// set fires and is brought back afterwards, and a session that never comes
    /// back leaves the operator aiming blind for the rest of the shoot.
    func testTheViewfinderComesBackAfterBeingStopped() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        XCTAssertTrue(rig.session.isRunning, "the session did not come up")

        rig.stopSession()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(rig.session.isRunning, "the session did not go down")

        // What `startFraming()` does between sets.
        await rig.startSessionAndWait()
        XCTAssertTrue(rig.session.isRunning, "the viewfinder did not come back after a set")
    }

    /// Swapping sensors mid-station reconfigures a *running* session. Doing that
    /// on the wrong thread is the classic cause of a black preview or a capture
    /// that never fires, so it is worth exercising directly.
    func testReconfiguringARunningSessionSurvivesASwap() async throws {
        try XCTSkipUnless(report.usableSensors.count > 1, "needs two sensors")
        try await rig.configure(report.usableSensors[0].sensor)
        await rig.startSessionAndWait()
        try await rig.configure(report.usableSensors[1].sensor)
        await rig.startSessionAndWait()
        XCTAssertTrue(rig.session.isRunning)
        XCTAssertEqual(rig.sensor, report.usableSensors[1].sensor)
    }

    // MARK: - Exposure

    func testExposureLockLandsOnWhatWasAsked() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()

        let shutter = 1.0 / 125
        let iso = max(firstSensor.minISO ?? 100, 100)
        let achieved = try await rig.lockExposure(shutterSeconds: shutter, iso: iso)

        // The device quantises to what its clock can express, so this is a
        // tolerance rather than an equality — but a 5% miss would mean the
        // protocol's demand is not what fired.
        XCTAssertEqual(achieved.shutterSeconds, shutter, accuracy: shutter * 0.05,
                       "the device did not honour the requested shutter")
        XCTAssertEqual(achieved.iso, iso, accuracy: iso * 0.05,
                       "the device did not honour the requested ISO")
    }

    /// Rails are validated and the rung is refused, never clamped — a clamped
    /// rung fires at a value nobody asked for and reads back as the request.
    func testAnImpossibleShutterIsRefusedRatherThanClamped() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        do {
            _ = try await rig.lockExposure(shutterSeconds: 3600, iso: 100)
            XCTFail("a one-hour exposure should have been refused")
        } catch let error as CaptureRig.RigError {
            XCTAssertTrue("\(error)".contains("rails"), "refused, but not for the stated reason")
        }
    }

    // MARK: - Capture

    func testASingleCaptureProducesABayerDNGThatAgreesWithTheRequest() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()

        let shutter = 1.0 / 125
        let iso = max(firstSensor.minISO ?? 100, 100)
        _ = try await rig.lockWhiteBalance()
        _ = try await rig.lockExposure(shutterSeconds: shutter, iso: iso)
        let photo = try await rig.captureSingle()

        let data = try XCTUnwrap(photo.fileDataRepresentation(), "the photo carries no file")
        XCTAssertGreaterThan(data.count, 1_000_000, "a full-frame Bayer DNG should not be tiny")

        // The DNG's own claim about itself is a separate witness from the
        // request, and the disagreement between them is the finding.
        let witness = DNGMetadata.read(data)
        let dngShutter = try XCTUnwrap(witness.exposureTimeSeconds,
                                       "the DNG carries no exposure time")
        XCTAssertEqual(dngShutter, shutter, accuracy: shutter * 0.05,
                       "the written file disagrees with what was requested")
        XCTAssertNotNil(witness.activeArea, "no ActiveArea — clipping stats would be unavailable")
        XCTAssertNotNil(witness.blackLevel, "no BlackLevel in the written file")
    }

    /// Clipping statistics are computed over the active area from the Bayer
    /// buffer. If they come back unavailable, every exposure decision made off
    /// this app's output is unsupported.
    func testClippingStatisticsAreActuallyComputable() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockExposure(shutterSeconds: 1.0 / 125,
                                       iso: max(firstSensor.minISO ?? 100, 100))
        let photo = try await rig.captureSingle()
        let data = try XCTUnwrap(photo.fileDataRepresentation())
        let witness = DNGMetadata.read(data)

        let stats = ClippingStats.compute(
            from: photo, bayerFormat: rig.bayerFormat,
            activeArea: witness.activeArea,
            blackLevel: witness.blackLevel?.first,
            whiteLevel: witness.whiteLevel?.first)

        XCTAssertNil(stats.unavailableReason, "clipping statistics unavailable")
        XCTAssertEqual(stats.channels.count, 4, "a Bayer CFA has four channels")
        for ch in stats.channels {
            XCTAssertGreaterThan(ch.p50, 0, "\(ch.colour) has a zero median")
        }
    }

    func testAHardwareBracketReturnsOnePhotoPerRung() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockWhiteBalance()

        let iso = max(firstSensor.minISO ?? 100, 100)
        let specs = [1.0 / 250, 1.0 / 125, 1.0 / 60].map {
            CaptureSpec(shutterSeconds: $0, iso: iso)
        }
        let photos = try await rig.captureBracket(specs)
        XCTAssertEqual(photos.count, specs.count, "the bracket did not deliver every rung")

        // Each rung should carry its own exposure — a bracket that fires three
        // identical frames is the failure worth catching here.
        let written = photos.compactMap { $0.fileDataRepresentation() }
            .compactMap { DNGMetadata.read($0).exposureTimeSeconds }
        XCTAssertEqual(written.count, specs.count)
        XCTAssertEqual(Set(written.map { ($0 * 100_000).rounded() }).count, specs.count,
                       "the rungs all fired at the same exposure: \(written)")
    }

    func testABracketBeyondTheHardwareMaximumIsRefused() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        let tooMany = (0...rig.maxBracketCount).map { _ in
            CaptureSpec(shutterSeconds: 1.0 / 125, iso: max(firstSensor.minISO ?? 100, 100))
        }
        do {
            _ = try await rig.captureBracket(tooMany)
            XCTFail("a bracket past maxBracketedCapturePhotoCount should be refused")
        } catch let error as CaptureRig.RigError {
            XCTAssertTrue("\(error)".contains("maxBracketedCapturePhotoCount"))
        }
    }

    // MARK: - Landing on disk

    /// The whole point is a file that survives. This writes one through the
    /// real store and reads it back, then cleans up after itself.
    func testAFrameWrittenThroughTheStoreIsReadableAfterwards() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockExposure(shutterSeconds: 1.0 / 125,
                                       iso: max(firstSensor.minISO ?? 100, 100))
        let photo = try await rig.captureSingle()
        let data = try XCTUnwrap(photo.fileDataRepresentation())

        let session = try SessionStore.open(capability: report)
        defer { try? SessionStore.deleteSession(session.sessionId) }

        let name = SessionStore.frameFilename(
            sessionId: session.sessionId, station: 1, bracket: 1, frame: 1,
            sensor: firstSensor.sensor.rawValue)
        let url = try SessionStore.writeFrame(data, named: name, sessionId: session.sessionId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let readBack = try Data(contentsOf: url)
        XCTAssertEqual(readBack.count, data.count, "the file on disk is not what was written")
        XCTAssertNotNil(DNGMetadata.read(readBack).exposureTimeSeconds,
                        "the written file no longer parses as a DNG")
    }
}

/// The bench's headline list is derived arithmetic over the probe, so it is
/// worth checking against real hardware that it says something true and
/// specific rather than something vacuous.
final class DeviceCapabilitySummaryTests: XCTestCase {

    func testTheBenchDescribesThisDeviceInConcreteTerms() throws {
        let report = CapabilityProbe.run()
        try XCTSkipUnless(report.canCapture, "no Bayer sensor — device-only test")

        let capabilities = report.capabilities
        XCTAssertGreaterThanOrEqual(capabilities.count, 4,
                                    "a usable device should describe more than a refusal")
        for c in capabilities {
            print("BENCH · \(c.isConstraint ? "⚠︎" : "✓") \(c.headline)\n         \(c.detail)")
            XCTAssertFalse(c.headline.isEmpty)
            XCTAssertFalse(c.detail.isEmpty)
        }

        XCTAssertGreaterThan(report.sharedBracketCeiling, 0,
                             "the shared bracket ceiling should be a real number")
        XCTAssertLessThanOrEqual(report.sharedBracketCeiling, report.deepestBracketCeiling)
        let shutter = try XCTUnwrap(report.shutterRange)
        XCTAssertLessThan(shutter.min, shutter.max)
        print("BENCH · shutter \(shutter.min)–\(shutter.max)s, "
              + "bracket \(report.sharedBracketCeiling)–\(report.deepestBracketCeiling), "
              + "rails differ: \(report.sensorsDisagreeOnRails)")
    }
}
