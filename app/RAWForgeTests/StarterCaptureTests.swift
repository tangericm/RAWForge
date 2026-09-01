import XCTest
@testable import RAWForge

/// The first-use path is only a shorter way to author real protocols. These
/// tests keep the shortcut from quietly becoming a second, weaker recipe
/// format as the interface evolves.
final class StarterCaptureTests: XCTestCase {

    private var createdProtocolNames: [String] = []

    override func tearDown() {
        for name in createdProtocolNames { ProtocolLibrary.delete(named: name) }
        createdProtocolNames = []
        super.tearDown()
    }

    func testExposureLadderIsASevenFrameOneStopBurst() {
        let set = StarterCapture.exposureLadder.captureSet(firing: .hardwareBracket)

        XCTAssertEqual(set.name, "Exposure Ladder · Burst")
        XCTAssertEqual(set.version, 0, "the library assigns version one when it is materialized")
        XCTAssertEqual(set.specs.count, 7)
        XCTAssertEqual(set.specs[3], CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100))
        XCTAssertEqual(set.specs.first!.shutterSeconds, 1.0 / 1000, accuracy: 1e-12)
        XCTAssertEqual(set.specs.last!.shutterSeconds, 8.0 / 125, accuracy: 1e-12)
        XCTAssertEqual(set.firing, .hardwareBracket)
    }

    func testRepeatCanBeMaterializedAsSequentialWithoutChangingItsFrames() {
        let set = StarterCapture.repeat16.captureSet(firing: .sequential)

        XCTAssertEqual(set.name, "Repeat 16 · Sequential")
        XCTAssertEqual(set.specs.count, 16)
        XCTAssertTrue(set.specs.allSatisfy {
            $0 == CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100)
        })
        XCTAssertEqual(set.firing, .sequential)
    }

    func testSingleFrameDoesNotOfferAMeaninglessFiringChoice() {
        XCTAssertEqual(StarterCapture.single.allowedFiringModes, [.hardwareBracket])
        let set = StarterCapture.single.captureSet(firing: .sequential)

        XCTAssertEqual(set.name, "Single Frame")
        XCTAssertEqual(set.specs.count, 1)
        XCTAssertEqual(set.firing, .hardwareBracket)
    }

    func testMaterializingTheSameStarterReusesItsExistingVersion() throws {
        let name = "TEST Starter \(UUID().uuidString)"
        var suggested = CaptureSet.repeated(
            CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
            count: 16, name: name, version: 0)
        suggested.executionMode = .hardwareBracket
        createdProtocolNames.append(name)

        let first = try ProtocolLibrary.materializeStarter(suggested)
        let second = try ProtocolLibrary.materializeStarter(suggested)

        XCTAssertEqual(first.name, name)
        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(second, first, "choosing the same starter again must not pretend it was edited")
    }

    func testMaterializingAStarterNeverOverwritesACustomizedProtocol() throws {
        let name = "TEST Starter \(UUID().uuidString)"
        let custom = CaptureSet.repeated(
            CaptureSpec(shutterSeconds: 1.0 / 30, iso: 200),
            count: 3, name: name)
        _ = try ProtocolLibrary.save(custom, as: name)
        createdProtocolNames += [name, "\(name) 2"]

        var suggested = CaptureSet.repeated(
            CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100),
            count: 16, name: name, version: 0)
        suggested.executionMode = .sequential
        let generated = try ProtocolLibrary.materializeStarter(suggested)

        XCTAssertEqual(generated.name, "\(name) 2")
        XCTAssertEqual(generated.version, 1)
        XCTAssertEqual(generated.specs.count, 16)
        XCTAssertEqual(generated.firing, .sequential)
        XCTAssertEqual(ProtocolLibrary.load(named: name)?.specs, custom.specs,
                       "the user's recipe under the suggested name must survive untouched")
    }
}
