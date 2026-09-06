import XCTest
@testable import RAWForge

final class CaptureSetEditorDraftTests: XCTestCase {
    func testStaleSingleFrameTitleIsRepairedByAnExactFrameEdit() {
        let specs = [0.01, 0.02, 0.03, 0.04].map { CaptureSpec(shutterSeconds: $0, iso: 100) }
        let stale = CaptureSet(name: "Single Frame", version: 0, specs: specs,
            generator: .manual, perSensorEVOffsetStops: [:], executionMode: .sequential)
        let edited = edit(stale, firing: .sequential)
        XCTAssertEqual(edited.name, "Frames 4 · Sequential")
        XCTAssertEqual(edited.specs, specs)
        XCTAssertEqual(edit(edited, firing: .hardwareBracket).name, "Frames 4 · Burst")
        let repeated = CaptureSet.repeated(specs[0], count: 2)
        XCTAssertEqual(edit(edited, replacement: repeated, firing: .sequential).name, "Repeat 2 · Sequential")
    }

    func testPreviouslySavedStaleStarterTitleIsRepairedOnEdit() throws {
        let replacement = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.02, iso: 200), count: 4)
        for staleName in ["Repeat 16 · Burst", "Single Frame", "Exposure Ladder · Burst"] {
            let stale = CaptureSet(name: staleName, version: 0, specs: replacement.specs,
                generator: replacement.generator, perSensorEVOffsetStops: [:], executionMode: .sequential)
            let restored = try JSONDecoder().decode(CaptureSet.self, from: JSONEncoder().encode(stale))
            XCTAssertEqual(edit(restored, firing: .sequential).name, "Repeat 4 · Sequential")
        }
    }

    func testGeneratedRepeatTitleTracksFiringInBothDirections() {
        let burst = StarterCapture.repeat16.captureSet(firing: .hardwareBracket)
        let sequential = edit(burst, firing: .sequential)
        XCTAssertEqual(sequential.name, "Repeat 16 · Sequential")
        XCTAssertEqual(sequential.firing, .sequential)
        XCTAssertEqual(edit(sequential, firing: .hardwareBracket).name, "Repeat 16 · Burst")
    }

    func testGeneratedRepeatTitleTracksReplacementCountAndMode() {
        let original = StarterCapture.repeat16.captureSet(firing: .hardwareBracket)
        let replacement = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.02, iso: 200), count: 4)
        let edited = edit(original, replacement: replacement, firing: .sequential)
        XCTAssertEqual(edited.name, "Repeat 4 · Sequential")
        XCTAssertEqual(edited.specs, replacement.specs)
        XCTAssertEqual(edited.generator, replacement.generator)
        XCTAssertEqual(edited.firing, .sequential)
        XCTAssertEqual(edited.version, original.version)
    }

    func testGeneratedLadderTitleTracksFiring() {
        let original = StarterCapture.exposureLadder.captureSet(firing: .hardwareBracket)
        XCTAssertEqual(edit(original, firing: .sequential).name, "Exposure Ladder · Sequential")
    }

    func testGeneratedSingleTitleChangesWhenReplacedWithMultipleFrames() {
        let original = StarterCapture.single.captureSet(firing: .hardwareBracket)
        let replacement = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.02, iso: 200), count: 4)
        XCTAssertEqual(edit(original, replacement: replacement, firing: .sequential).name, "Repeat 4 · Sequential")
    }

    func testAuthoredNamesSurviveModeAndCountChanges() {
        let replacement = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.02, iso: 200), count: 4)
        let fixtures: [(String, StarterCapture)] = [
            ("Window study · Burst", .repeat16), ("Repeat 16 · Burst", .repeat16),
            ("Exposure Ladder · Burst", .exposureLadder), ("Single Frame", .single),
            ("Frames 4 · Burst", .repeat16)
        ]
        for (name, starter) in fixtures {
            // Library saves assign a positive version, including explicitly
            // authored names that happen to match a starter's generated title.
            let template = starter.captureSet(firing: .hardwareBracket)
            let original = CaptureSet(name: name, version: 3, specs: template.specs,
                generator: template.generator, perSensorEVOffsetStops: ["1x": 0.5],
                executionMode: .hardwareBracket)
            let edited = edit(original, replacement: replacement, firing: .sequential)
            XCTAssertEqual(edited.name, name)
            XCTAssertEqual(edited.version, 3)
            XCTAssertEqual(edited.perSensorEVOffsetStops, ["1x": 0.5])
            XCTAssertEqual(edited.specs.count, 4)
            XCTAssertEqual(edited.firing, .sequential)
        }
    }

    func testUnversionedCustomNameIsNotTreatedAsGenerated() {
        let original = CaptureSet.repeated(CaptureSpec(shutterSeconds: 0.01, iso: 100), count: 16,
                                           name: "Window study · Burst", version: 0)
        XCTAssertEqual(edit(original, firing: .sequential).name, "Window study · Burst")
    }

    private func edit(_ original: CaptureSet, replacement: CaptureSet? = nil,
                      firing: ExecutionMode) -> CaptureSet {
        CaptureSetEditorDraft.replacing(original, specs: replacement?.specs ?? original.specs,
            generator: replacement?.generator ?? original.generator, firing: firing,
            offsets: original.perSensorEVOffsetStops)
    }
}
