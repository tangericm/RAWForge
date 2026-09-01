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

    /// Re-arming a set on the sensor already feeding the preview must not tear
    /// down and rebuild the capture graph. Input identity is the observable
    /// boundary: rebuilding produces a different `AVCaptureDeviceInput`, while
    /// an idempotent configure leaves the live graph alone.
    func testConfiguringTheCurrentSensorPreservesTheLiveInput() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        let original = try XCTUnwrap(rig.session.inputs.first)

        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()

        XCTAssertTrue(original === rig.session.inputs.first,
                      "same-sensor configure rebuilt the live capture graph")
        XCTAssertTrue(rig.session.isRunning)
    }

    #if !DEBUG
    /// Keeps the cost visible on real optimized hardware. The identity
    /// assertion is the correctness contract; the broad 10 ms p90 ceiling
    /// catches an implementation that technically reuses the input but puts
    /// expensive synchronous work in the no-op path.
    func testReleaseSameSensorReuseCost() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        let original = try XCTUnwrap(rig.session.inputs.first)
        var elapsed: [TimeInterval] = []

        for _ in 0..<7 {
            let began = ProcessInfo.processInfo.systemUptime
            try await rig.configure(firstSensor.sensor)
            await rig.startSessionAndWait()
            elapsed.append(ProcessInfo.processInfo.systemUptime - began)
        }

        let sorted = elapsed.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[Int(ceil(Double(sorted.count) * 0.90)) - 1]
        let result = String(format:
            "RAWFORGE_SAME_SENSOR_BENCHMARK samples_ms=%@ median_ms=%.3f p90_ms=%.3f",
            sorted.map { String(format: "%.3f", $0 * 1_000) }.joined(separator: ","),
            median * 1_000, p90 * 1_000)
        print(result)
        add(XCTAttachment(string: result))

        XCTAssertTrue(original === rig.session.inputs.first,
                      "same-sensor configure rebuilt the live capture graph")
        XCTAssertLessThan(p90, 0.010,
                          "reusing an active sensor should take less than 10 ms")
    }

    /// Exercises the production Bench path rather than only the primitive it
    /// calls. This proves a real characterisation publishes the new reading
    /// that estimates and the timeline consume.
    func testReleaseCharacterisationPublishesSameSensorSetup() async throws {
        let profile = try await DeviceCharacterisation.run(rig: rig, report: report)
        let reading = try XCTUnwrap(profile.sameSensorSetup)

        XCTAssertTrue(reading.isMeasured)
        XCTAssertEqual(reading.sampleCount, 7)
        XCTAssertLessThan(reading.value, 0.010,
                          "characterisation did not use the cheap same-sensor path")
    }

    /// #33 appeared only after repeating the production Bench path: one run
    /// could pass, then a later maximum-size RAW bracket invalidated the camera
    /// service until the phone restarted. Three runs in one process preserve
    /// that state and a final independent frame proves the service is still
    /// usable rather than merely that the last profile returned.
    func testReleaseThreeCharacterisationsLeaveTheCameraUsable() async throws {
        for run in 1...3 {
            let profile = try await DeviceCharacterisation.run(rig: rig, report: report)
            XCTAssertTrue(profile.sensorFramePeriod.isMeasured, "run \(run) did not finish")
            XCTAssertTrue(profile.bracketSeam.isMeasured, "run \(run) did not cross a seam")
        }

        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockExposure(shutterSeconds: 1.0 / 250,
                                       iso: max(firstSensor.minISO ?? 100, 100))
        let photo = try await rig.captureSingle()
        XCTAssertGreaterThan(photo.fileDataRepresentation()?.count ?? 0, 1_000_000,
                             "the Bench returned, but the next RAW capture did not")
    }
    #endif

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

    #if !DEBUG
    /// Measures the exact synchronous work performed by `CaptureModel.bank`.
    ///
    /// File serialization and DNG parsing happen before the stopwatch because
    /// this ticket asks one narrow question: whether the full-pixel histogram
    /// itself is cheap enough to keep between photo delivery and the next
    /// hardware request. Eight real bracket buffers make this the same memory
    /// shape as production, not a synthetic allocation with friendlier caches.
    ///
    /// The 100 ms p90 budget is deliberately generous but consequential: at
    /// that boundary clipping alone adds 6.4 seconds to a 64-frame set. Above
    /// it the computation must leave the synchronous capture path; below it the
    /// printed and attached result lets future device runs expose regressions.
    func testReleaseClippingStatisticsStayInsideCapturePathBudget() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()

        let frameCount = min(8, rig.maxBracketCount)
        try XCTSkipUnless(frameCount >= 3, "needs at least three bracket buffers")
        let shutter = 1.0 / 125.0
        let iso = max(firstSensor.minISO ?? 100, 100)
        let specs = Array(repeating: CaptureSpec(shutterSeconds: shutter, iso: iso),
                          count: frameCount)
        var elapsed: [TimeInterval] = []

        let requestSizes = try await rig.captureBracket(specs) { photo, _ in
            let data = try XCTUnwrap(photo.fileDataRepresentation())
            let witness = DNGMetadata.read(data)

            let began = ProcessInfo.processInfo.systemUptime
            let stats = ClippingStats.compute(
                from: photo, bayerFormat: rig.bayerFormat,
                activeArea: witness.activeArea,
                blackLevel: witness.blackLevel?.first,
                whiteLevel: witness.whiteLevel?.first)
            elapsed.append(ProcessInfo.processInfo.systemUptime - began)

            XCTAssertNil(stats.unavailableReason)
            XCTAssertEqual(stats.channels.count, 4)
        }

        XCTAssertEqual(requestSizes, [frameCount])
        XCTAssertEqual(elapsed.count, frameCount)

        let sorted = elapsed.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        let p90 = sorted[Int(ceil(Double(sorted.count) * 0.90)) - 1]
        let milliseconds = sorted.map { $0 * 1_000 }
        let result = String(format:
            "RAWFORGE_CLIPPING_BENCHMARK samples_ms=%@ median_ms=%.3f p90_ms=%.3f max_ms=%.3f",
            milliseconds.map { String(format: "%.3f", $0) }.joined(separator: ","),
            median * 1_000, p90 * 1_000, (sorted.last ?? 0) * 1_000)
        print(result)
        add(XCTAttachment(string: result))

        XCTAssertLessThan(p90, 0.100,
                          "clipping p90 exceeds 100 ms/frame; move it off the capture path")
    }
    #endif

    func testAHardwareBracketReturnsOnePhotoPerRung() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockWhiteBalance()

        let iso = max(firstSensor.minISO ?? 100, 100)
        let specs = [1.0 / 250, 1.0 / 125, 1.0 / 60].map {
            CaptureSpec(shutterSeconds: $0, iso: iso)
        }
        var written: [Double] = []
        let sizes = try await rig.captureBracket(specs) { photo, _ in
            // Each rung should carry its own exposure — a bracket that fires
            // three identical frames is the failure worth catching here.
            if let data = photo.fileDataRepresentation(),
               let t = DNGMetadata.read(data).exposureTimeSeconds { written.append(t) }
        }
        XCTAssertEqual(sizes, [specs.count],
                       "a set inside the ceiling should fire as one request")
        XCTAssertEqual(written.count, specs.count)
        XCTAssertEqual(Set(written.map { ($0 * 100_000).rounded() }).count, specs.count,
                       "the rungs all fired at the same exposure: \(written)")
    }

    /// One frame past the ceiling used to abort the station and delete its
    /// frames. The ceiling is knowable before anything fires, so nothing was
    /// learned by discovering it mid-set — it now splits.
    func testOneFramePastTheCeilingSplitsRatherThanAborting() async throws {
        try await rig.configure(firstSensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockWhiteBalance()

        let ceiling = rig.maxBracketCount
        try XCTSkipUnless(ceiling > 0, "this sensor has no hardware bracket")
        let specs = (0...ceiling).map { _ in
            CaptureSpec(shutterSeconds: 1.0 / 250, iso: max(firstSensor.minISO ?? 100, 100))
        }
        var delivered = 0
        let sizes = try await rig.captureBracket(specs) { _, _ in delivered += 1 }
        XCTAssertEqual(delivered, ceiling + 1, "a frame was lost at the boundary")
        XCTAssertEqual(sizes, [ceiling, 1])
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

        let header = try Data(contentsOf: SessionStore.directory(for: session.sessionId)
            .appendingPathComponent("session.json"))
        XCTAssertFalse(String(decoding: header, as: UTF8.self).contains("openedAtUptime"),
                       "the live store must not persist the phone's boot-time clock")

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

/// A capture set longer than the sensor's hardware bracket ceiling.
///
/// This used to abort the station — the condition is knowable before anything
/// fires, so discovering it at frame nine cost a pose for nothing. It now
/// splits across requests, and the question this answers is what that costs:
/// frames inside one request are pipeline-bound, and the seam between two
/// requests is a second capture round trip.
final class BracketSplittingTests: XCTestCase {

    func testASetPastTheCeilingSplitsAndTheSeamsAreMeasured() async throws {
        let report = CapabilityProbe.run()
        try XCTSkipUnless(report.canCapture, "no Bayer sensor — device-only test")
        let sensor = report.usableSensors[0]
        let rig = CaptureRig()
        defer { rig.stopSession() }

        try await rig.configure(sensor.sensor)
        await rig.startSessionAndWait()
        _ = try await rig.lockWhiteBalance()

        let ceiling = rig.maxBracketCount
        let wanted = 16
        try XCTSkipUnless(ceiling > 0 && ceiling < wanted,
                          "this sensor's ceiling is not below \(wanted)")

        let iso = max(sensor.minISO ?? 100, 100)
        let specs = (0..<wanted).map { _ in CaptureSpec(shutterSeconds: 1.0 / 250, iso: iso) }

        let began = ProcessInfo.processInfo.systemUptime
        var stamps: [Double] = []
        let requestSizes = try await rig.captureBracket(specs) { photo, _ in
            stamps.append(photo.timestamp.seconds)
        }
        let wall = ProcessInfo.processInfo.systemUptime - began

        XCTAssertEqual(stamps.count, wanted, "not every frame came back")
        XCTAssertEqual(requestSizes.reduce(0, +), wanted)
        XCTAssertEqual(requestSizes.count, Int(ceil(Double(wanted) / Double(ceiling))))
        XCTAssertTrue(requestSizes.allSatisfy { $0 <= ceiling },
                      "a request exceeded the ceiling: \(requestSizes)")

        // Where the seams fall, by cumulative index.
        var seams: Set<Int> = []
        var running = 0
        for size in requestSizes.dropLast() { running += size; seams.insert(running) }

        var inside: [Double] = [], across: [Double] = []
        for i in 1..<stamps.count {
            let gap = stamps[i] - stamps[i - 1]
            if seams.contains(i) { across.append(gap) } else { inside.append(gap) }
        }

        print("SPLIT · \(wanted) frames as \(requestSizes) in "
              + String(format: "%.2f s wall clock", wall))
        print(String(format: "SPLIT · gap inside a request: median %.1f ms over %d",
                     1000 * median(inside), inside.count))
        print(String(format: "SPLIT · gap across a seam:    median %.1f ms over %d",
                     1000 * median(across), across.count))

        XCTAssertFalse(inside.isEmpty)
        XCTAssertFalse(across.isEmpty)
        // The seam is a second round trip through the pipeline, so it must cost
        // *something* — if it did not, the ceiling would not exist.
        XCTAssertGreaterThan(median(across), median(inside),
                             "the seam should cost more than an in-request gap")
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
                                : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
