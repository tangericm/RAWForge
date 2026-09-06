import XCTest

/// Real SwiftUI navigation and Recipe persistence. Camera capture is deliberately
/// not simulated here: controller integration tests cover transaction semantics.
final class WorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["RAWFORGE_UI_TESTING"] = "1"
        app.launchEnvironment["RAWFORGE_DEMO"] = "shoot"
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    func testShootLibraryAndPrivacyAreReachableWithoutOpeningARun() {
        app.launch()
        XCTAssertTrue(app.buttons["Capture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Capture"].isEnabled)
        XCTAssertFalse(app.buttons["Run"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 2)
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Captured Runs"].waitForExistence(timeout: 3))
        app.buttons["Help & Settings"].tap()
        app.buttons["Privacy & Data"].tap()
        XCTAssertTrue(app.navigationBars["Privacy & Data"].waitForExistence(timeout: 3))
    }

    func testSavingAnEditCreatesVersionAndCancelKeepsSavedName() {
        app.launch()
        openEditor()
        replace(app.textFields["Recipe name"], with: "Window study")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Window study"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "v2")).firstMatch.exists)
        openEditor()
        replace(app.textFields["Recipe name"], with: "Discard this draft")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Window study"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Discard this draft"].exists)
    }

    func testSequentialIntervalRequiresConfirmationBeforeBurstRemovesIt() {
        app.launch()
        openEditor()
        app.buttons["recipe.step.1"].tap()
        XCTAssertFalse(app.textFields["step.interval"].exists)
        app.segmentedControls.buttons["Sequential"].tap()
        let interval = app.textFields["step.interval"]
        XCTAssertTrue(interval.waitForExistence(timeout: 3))
        replace(interval, with: "0.5")
        app.segmentedControls.buttons["Burst"].tap()
        app.buttons["Keep Sequential"].tap()
        XCTAssertEqual(interval.value as? String, "0.5")
        app.segmentedControls.buttons["Burst"].tap()
        app.buttons["Use Burst and remove frame interval"].tap()
        XCTAssertFalse(interval.exists)
    }

    func testAddingARepeatKeepsStepOrderAndUpdatesTheCaptureSummary() {
        app.launch()
        openEditor()
        app.buttons["Add Step"].tap()
        app.buttons["Repeat 16 · Burst"].tap()
        XCTAssertTrue(app.buttons["recipe.step.2"].waitForExistence(timeout: 3))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["2 steps · 17 frames · v2"].waitForExistence(timeout: 3))
        openEditor()
        XCTAssertTrue(app.buttons["recipe.step.1"].label.contains("Single Frame"))
        XCTAssertTrue(app.buttons["recipe.step.2"].label.contains("Repeat 16"))
    }

    /// A06: the generated title must agree with the mode after saving and reopening.
    func testAuditRepeatTitleDoesNotKeepBurstAfterSwitchingToSequential() {
        app.launch()
        openEditor()
        app.buttons["Add Step"].tap()
        app.buttons["Repeat 16 · Burst"].tap()
        let step = app.buttons["recipe.step.2"]
        XCTAssertTrue(step.waitForExistence(timeout: 3))
        step.tap()
        app.segmentedControls.buttons["Sequential"].tap()
        XCTAssertTrue(app.textFields["step.interval"].waitForExistence(timeout: 3))
        app.navigationBars["Edit Step"].buttons["BackButton"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["2 steps · 17 frames · v2"].waitForExistence(timeout: 3))

        openEditor()
        XCTAssertTrue(step.waitForExistence(timeout: 3))
        let label = step.label
        XCTAssertTrue(label.contains("Repeat 16 · Sequential"), "Generated title must reflect saved firing: \(label)")
        XCTAssertFalse(label.contains("Burst"), "Generated title must not contradict saved firing: \(label)")
        step.tap()
        XCTAssertTrue(app.segmentedControls.buttons["Sequential"].isSelected)
        XCTAssertTrue(app.textFields["step.interval"].exists)
    }

    func testCaptureAndRecipeEditingRemainReachableAtLargestTextSize() {
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let capture = app.buttons["Capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        XCTAssertTrue(capture.isHittable)
        XCTAssertGreaterThanOrEqual(capture.frame.height, 44)
        attachShootScreen("Shoot · largest text")
        openEditor()
        XCTAssertTrue(app.buttons["Save"].isHittable)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
    }

    /// A height cap must not shrink the portrait viewfinder into a narrow tile.
    func testViewfinderUsesScreenWidthWithoutCroppingOrHidingCapture() {
        app.launch()
        let preview = app.otherElements["viewfinder.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(preview.frame.width, app.frame.width * 0.85)
        XCTAssertEqual(preview.frame.width / preview.frame.height, 0.75, accuracy: 0.01)
        XCTAssertLessThanOrEqual(preview.frame.maxY, app.buttons["Capture"].frame.minY - 16,
                                 "The full viewfinder must clear the pinned capture bar")
        XCTAssertTrue(app.buttons["Capture"].isHittable)
        attachShootScreen("Shoot · full-width preview")
        let focus = app.buttons["Focus"]
        if !focus.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(focus.isHittable)
    }

    private func attachShootScreen(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func openEditor() {
        let edit = app.buttons["Edit Recipe"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.textFields["Recipe name"].waitForExistence(timeout: 3))
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }
}
