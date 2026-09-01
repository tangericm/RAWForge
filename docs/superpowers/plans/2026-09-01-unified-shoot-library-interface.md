# Unified Shoot and Library Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four-tab/manual-lifecycle interface with a production-ready Shoot + Library product that preserves exact Recipe controls, witnesses, diagnostics, and device information.

**Architecture:** `RecipeCoordinator` owns workflow intent; focused screen models derive presentation without republishing through `CaptureModel`. Shoot is camera-first and dispatches one capture intent. Library presents Recipes and Runs/Takes through one navigation hierarchy. Existing technical views are reused behind progressively disclosed, user-language routes.

**Tech Stack:** SwiftUI, AVFoundation preview layer, XCTest presentation tests, XCUITest with deterministic demo adapters, SF Symbols, existing dark design system.

**Spec:** `docs/superpowers/specs/2026-09-01-unified-workflow-compliance-design.md`

## Global Constraints

- Complete the privacy and orchestration plans first.
- Exactly two release tabs: Shoot and Library.
- Console and Bench are not release tabs; their useful information remains in Help & Settings.
- The selected Recipe, compatibility, frame count, duration, storage, and firing are visible before Capture.
- Expert controls are no deeper than Step → Advanced.
- Focus is current-Take state, not reusable Recipe state.
- Burst and Sequential always remain visible and separately explained.
- Gap is rendered only for Sequential.
- Status never relies on color alone; controls retain 44-point minimum targets.
- v1 remains dark-only and portrait-only.
- Development demos and instrument checks stay behind `#if DEBUG` and fail the existing Release scan if leaked.

---

### Task 1: Establish presentation models and a small design system

**Files:**
- Create: `app/RAWForge/UI/Design/RAWForgeTheme.swift`
- Create: `app/RAWForge/UI/Shoot/ShootPresentation.swift`
- Create: `app/RAWForge/UI/Recipe/RecipePresentation.swift`
- Create: `app/RAWForgeTests/WorkflowPresentationTests.swift`

**Interfaces:**
- Produces: `ShootPresentation.State`
- Produces: `RecipePresentation.summary(recipe:validation:estimate:)`
- Produces: shared spacing, corner radius, status style, and primary-action style
- Consumes: `RecipeCoordinator`, `SessionEstimate`, `RecipeValidation`, `TakeOutcome`

- [ ] **Step 1: Write pure presentation tests**

```swift
func testReadyStateNamesTheWholeActionAndCost() {
    let state = ShootPresentation.make(.readyFixture)
    XCTAssertEqual(state.primaryTitle, "Capture")
    XCTAssertEqual(state.recipeTitle, "Reflectance ladder")
    XCTAssertEqual(state.costLine, "42 frames · 14 s · about 420 MB")
}

func testSequentialStepMentionsGapAndBurstNeverDoes() {
    let sequential = RecipePresentation.step(.fixture(firing: .sequential, gap: 0.5))
    let burst = RecipePresentation.step(.fixture(firing: .hardwareBracket, gap: nil))
    XCTAssertTrue(sequential.detail.contains("0.5 s gap"))
    XCTAssertFalse(burst.detail.localizedCaseInsensitiveContains("gap"))
}

func testFailureCopySaysWhetherDataWasRetained() {
    let state = ShootPresentation.make(.failedFixture(retained: false, id: "A1B2"))
    XCTAssertTrue(state.message.contains("No Take was saved"))
    XCTAssertTrue(state.message.contains("A1B2"))
}
```

- [ ] **Step 2: Run `WorkflowPresentationTests` and confirm missing types**

- [ ] **Step 3: Implement deterministic presentation values**

`ShootPresentation.State` includes phase, primary title/icon/enabled state, Recipe title/detail, cost line, progress, status items, result message, and diagnostic ID. It maps controller/store state only; it performs no actions.

`RecipePresentation.StepSummary` includes sensor label, series label, frame count, firing label, exposure range, exact cost, compatibility symbol/text, and accessibility label. Derive it from domain values once so Shoot, editor, and Library do not invent separate copy.

- [ ] **Step 4: Define reusable visual tokens without a component framework**

```swift
enum RAWForgeTheme {
    static let cardRadius: CGFloat = 16
    static let screenPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let minimumTarget: CGFloat = 44
    static let captureTint = Color(red: 0.18, green: 0.52, blue: 1.0)
}
```

Provide modifiers for card surface and status label only. Do not wrap standard `Button`, `NavigationLink`, `List`, or `Form` in custom abstractions.

- [ ] **Step 5: Run tests and commit**

```bash
git add app/RAWForge/UI/Design app/RAWForge/UI/Shoot app/RAWForge/UI/Recipe \
  app/RAWForgeTests/WorkflowPresentationTests.swift
git commit -m "feat(ui): define unified workflow presentation"
```

---

### Task 2: Replace the app shell with Shoot and Library

**Files:**
- Modify: `app/RAWForge/UI/ContentView.swift`
- Create: `app/RAWForge/UI/AppTab.swift`
- Create: `app/RAWForge/UI/Library/LibraryRootView.swift`
- Modify: `app/RAWForge/UI/HelpSettingsView.swift`
- Modify: `app/RAWForge/UI/DemoSeed.swift`
- Create: `app/RAWForgeTests/AppNavigationTests.swift`

**Interfaces:**
- Produces: `AppTab.shoot/library`
- Produces: `LibrarySection.recipes/captures`
- Consumes: Help & Settings from compliance phase

- [ ] **Step 1: Write tab and route tests**

```swift
func testReleaseTopLevelHasExactlyShootAndLibrary() {
    XCTAssertEqual(AppTab.allCases, [.shoot, .library])
    XCTAssertEqual(AppTab.allCases.map(\.title), ["Shoot", "Library"])
}

func testLibrarySectionsAreNotAdditionalTabs() {
    XCTAssertEqual(LibrarySection.allCases, [.recipes, .captures])
}
```

- [ ] **Step 2: Run navigation tests and verify missing enums**

- [ ] **Step 3: Build the two-tab shell**

```swift
TabView(selection: $tab) {
    NavigationStack { ShootView(model: shootModel) }
        .tabItem { Label("Shoot", systemImage: "camera.aperture") }
        .tag(AppTab.shoot)
    NavigationStack { LibraryRootView(model: libraryModel) }
        .tabItem { Label("Library", systemImage: "square.stack") }
        .tag(AppTab.library)
}
```

Both roots expose the same gear toolbar button to `HelpSettingsView`. Preserve Booting and Camera Denied states, but Camera Denied still allows Library and Help & Settings: disable Shoot capture and show a permission remedy instead of replacing the entire app with a denial screen.

- [ ] **Step 4: Relocate old roots**

- `SessionBrowser` becomes a child of Library/Captures.
- `ProtocolLibraryView` becomes a compatibility source under Recipe add/import.
- `LogConsoleView` and log files move under Diagnostics.
- Bench capability/device profile/calibration move under This iPhone.
- `InstrumentChecksView` remains DEBUG-only under Diagnostics.

Delete only obsolete tab wrappers after every destination is reachable. Update demo environment parsing from integer tab indices to `RAWFORGE_START_TAB=shoot|library`.

- [ ] **Step 5: Run tests, Release scan, and commit**

Expected: simulator suite passes; Release has two tab titles and no developer-only symbols.

```bash
git add app/RAWForge/UI app/RAWForgeTests/AppNavigationTests.swift
git commit -m "feat(ui): reduce navigation to shoot and library"
```

---

### Task 3: Build the camera-first Shoot workspace

**Files:**
- Create: `app/RAWForge/UI/Shoot/ShootView.swift`
- Create: `app/RAWForge/UI/Shoot/ShootViewModel.swift`
- Create: `app/RAWForge/UI/Shoot/RecipeCard.swift`
- Create: `app/RAWForge/UI/Shoot/RunChip.swift`
- Create: `app/RAWForge/UI/Shoot/CaptureStatusStrip.swift`
- Create: `app/RAWForge/UI/Shoot/CaptureProgressCard.swift`
- Modify: `app/RAWForge/UI/PreviewView.swift`
- Modify: `app/RAWForge/UI/FocusPreflightView.swift`
- Create: `app/RAWForgeTests/ShootInteractionTests.swift`

**Interfaces:**
- Produces: `ShootView(model: ShootViewModel)`
- Consumes: `RecipeCoordinator.capture`, focus plan, live preview, presentation state
- Removes release dependence on: `CaptureFlowView`, `PlanSheet`, `performPrimaryAction`

- [ ] **Step 1: Write intent-routing tests for `ShootViewModel`**

```swift
@MainActor
func testPrimaryTapDispatchesOneCaptureIntentWhenReady() async {
    let h = ShootHarness.ready()
    await h.model.primaryTapped()
    XCTAssertEqual(h.coordinator.captureCalls, 1)
}

@MainActor
func testPrimaryTapOpensRecipeReviewWhenBlocked() async {
    let h = ShootHarness.blocked()
    await h.model.primaryTapped()
    XCTAssertEqual(h.model.route, .recipeCompatibility)
    XCTAssertEqual(h.coordinator.captureCalls, 0)
}
```

- [ ] **Step 2: Run focused tests and verify missing view model**

- [ ] **Step 3: Implement Shoot hierarchy**

Use a `ZStack`/safe-area layout: Run chip at top; preview fills available space; Recipe card and cost overlay sit above one large bottom Capture button; storage/thermal/motion status remains compact below the card. At large Dynamic Type, switch overlays into a vertically scrolling lower panel rather than clipping the preview controls.

The Recipe card always shows Recipe name/version, sensor sequence, total frames, Burst/Sequential labels, duration, storage, and compatibility. Capture is disabled only for a concrete blocker, storage hard fault, or active bank operation.

- [ ] **Step 4: Integrate focus without a mandatory preflight**

Tap on preview sets the current sensor's point focus. A focus button opens the existing per-sensor manual/automatic controls as a sheet. When a mapped point needs operator confirmation on another sensor, surface that sensor preview and marker in the sheet before capture. Add **Keep focus for repeated Takes** as explicit Take-state, default off.

The selected focus summary appears as a small preview badge; Recipe cards never display focus as part of the reusable definition.

- [ ] **Step 5: Implement progress, stop, and result behavior**

During capture, show Step number/name, Frame or burst progress, elapsed and estimated remaining time. The primary control label comes from active firing. Completed shows Capture Again plus Take detail link. Cancelled and failed state explicitly say no complete Take was saved and retain the diagnostic ID.

- [ ] **Step 6: Run presentation/full tests and commit**

```bash
git add app/RAWForge/UI/Shoot app/RAWForge/UI/PreviewView.swift \
  app/RAWForge/UI/FocusPreflightView.swift app/RAWForgeTests/ShootInteractionTests.swift
git commit -m "feat(ui): add camera-first shoot workspace"
```

---

### Task 4: Build the ordered-block Recipe library and editor

**Files:**
- Create: `app/RAWForge/UI/Recipe/RecipeListView.swift`
- Create: `app/RAWForge/UI/Recipe/RecipeDetailView.swift`
- Create: `app/RAWForge/UI/Recipe/RecipeEditorModel.swift`
- Create: `app/RAWForge/UI/Recipe/RecipeEditorView.swift`
- Create: `app/RAWForge/UI/Recipe/RecipeStepCard.swift`
- Create: `app/RAWForge/UI/Recipe/RecipeStepEditor.swift`
- Create: `app/RAWForge/UI/Recipe/RecipeAdaptationView.swift`
- Modify: `app/RAWForge/UI/ProtocolEditorView.swift`
- Create: `app/RAWForgeTests/RecipeEditorTests.swift`

**Interfaces:**
- Produces: `RecipeEditorModel.save() -> Recipe`
- Produces: ordered add/duplicate/delete/move operations
- Consumes: RecipeStore, ProtocolLibrary, RecipeValidator, SessionEstimate

- [ ] **Step 1: Write editor-state tests**

```swift
func testMovingAStepChangesAuthoredOrderAndNothingElse() {
    let model = RecipeEditorModel(recipe: .fixture(stepCount: 3), dependencies: .memory)
    let ids = model.draft.steps.map(\.id)
    model.move(from: IndexSet(integer: 0), to: 3)
    XCTAssertEqual(model.draft.steps.map(\.id), [ids[1], ids[2], ids[0]])
}

func testGapVisibilityTracksFiring() {
    let model = RecipeEditorModel(recipe: .fixture(firing: .hardwareBracket), dependencies: .memory)
    XCTAssertFalse(model.stepPresentation(0).showsGap)
    model.setFiring(.sequential, step: 0)
    XCTAssertTrue(model.stepPresentation(0).showsGap)
}

func testSaveCreatesANewVersionAndDoesNotMutateSource() throws {
    let model = RecipeEditorModel(recipe: .fixture(version: 3), dependencies: .memory)
    model.rename("Changed")
    XCTAssertEqual(try model.save().version, 4)
    XCTAssertEqual(model.source.name, "Fixture")
}
```

- [ ] **Step 2: Run editor tests and verify missing model**

- [ ] **Step 3: Build the collapsed ordered block list**

Each `RecipeStepCard` shows order, sensor, Single/Repeat/Exposure ladder, frames, firing, exact ladder bars, duration, storage, and compatibility. Use native move controls plus a large reorder handle. Opening a card presents `RecipeStepEditor`; no node canvas or wire UI is introduced.

- [ ] **Step 4: Implement exactly two disclosure levels**

Level one contains sensor, series shape, central shutter/ISO, count/rungs/spacing, firing, and its one-line explanation. Advanced contains per-sensor EV offset, dwell, Sequential-only gap, and rendered/dropped rungs. A Burst selection clears a draft gap only after a confirmation explaining the control is inapplicable; it never changes firing based on frame count.

- [ ] **Step 5: Implement selection, import, and adaptation**

Recipe list sorts by recent use and searches name, sensor, firing, and series shape. Add actions: New, Duplicate, Add from existing, Import. `RecipeAdaptationView` lists every dropped rung/change and saves only a new copy after confirmation. Missing sensors cannot be adapted automatically and show the exact requirement.

- [ ] **Step 6: Run editor, Recipe, estimate, and full tests; commit**

```bash
git add app/RAWForge/UI/Recipe app/RAWForge/UI/ProtocolEditorView.swift \
  app/RAWForgeTests/RecipeEditorTests.swift
git commit -m "feat(ui): add graphical recipe block editor"
```

---

### Task 5: Unify Runs, Takes, witnesses, export, and deletion in Library

**Files:**
- Create: `app/RAWForge/UI/Library/LibraryModel.swift`
- Create: `app/RAWForge/UI/Library/CaptureLibraryView.swift`
- Create: `app/RAWForge/UI/Library/RunRow.swift`
- Create: `app/RAWForge/UI/Library/RunDetailView.swift`
- Create: `app/RAWForge/UI/Library/TakeRow.swift`
- Create: `app/RAWForge/UI/Library/TakeDetailView.swift`
- Modify: `app/RAWForge/UI/SessionBrowser.swift`
- Modify: `app/RAWForge/UI/ClippingView.swift`
- Create: `app/RAWForgeTests/LibraryPresentationTests.swift`

**Interfaces:**
- Produces: `LibraryModel.runs`, `deleteRun`, `exportRun`, `finishActiveRun`
- Consumes: SessionStore detailed loaders, ActiveRunStore, RecipeSnapshot, SessionExport

- [ ] **Step 1: Write damaged/legacy/current presentation tests**

```swift
func testLegacyStationIsNamedLegacyCaptureWithoutGuessingRecipe() {
    let row = TakePresentation.make(.fixture(recipeSnapshot: nil))
    XCTAssertEqual(row.title, "Legacy capture")
}

func testUnreadableRecordIsListedByFilename() {
    let model = LibraryModel.fixture(unreadable: ["station-004.json"])
    XCTAssertEqual(model.runs[0].damagedItems, ["station-004.json"])
}

func testDeletingActiveRunRequiresFinishingItFirst() {
    let model = LibraryModel.fixture(activeRun: "R")
    XCTAssertEqual(model.deleteDisposition("R"), .finishThenConfirm)
}
```

- [ ] **Step 2: Run tests and confirm missing model/types**

- [ ] **Step 3: Build Runs and Takes hierarchy**

Run rows show date/name, Take count, Frame count, storage, and health. Take rows show Recipe snapshot or Legacy capture, pose, sensors, duration, storage, and witness summary. Take detail keeps exact exposure, focus, motion, clipping, DNG, timing, dropped-rung, and device evidence in labelled sections.

- [ ] **Step 4: Preserve safe storage actions**

Run export uses existing `SessionExport`. Run deletion retains confirmation naming size and count. The active Run must be finished before deletion. Take-level deletion is omitted from v1 unless `SessionStore` can prove selective deletion removes exactly its station JSON, frames, and motion stream; this preserves record integrity rather than presenting a partial action.

- [ ] **Step 5: Remove superseded session UI after parity check**

Compare every current `SessionBrowser` field/action against Run/Take views. Move thumbnail, archive sharing, corrupt-file surfacing, and size calculation before deleting old wrappers. Keep low-level schema/filename details under an Advanced record section.

- [ ] **Step 6: Run library/store/export tests and commit**

```bash
git add app/RAWForge/UI/Library app/RAWForge/UI/SessionBrowser.swift \
  app/RAWForge/UI/ClippingView.swift app/RAWForgeTests/LibraryPresentationTests.swift
git commit -m "feat(ui): unify recipes runs and takes in library"
```

---

### Task 6: Add deterministic interface and accessibility verification

**Files:**
- Modify: `app/project.yml`
- Create: `app/RAWForgeUITests/FirstCaptureUITests.swift`
- Create: `app/RAWForgeUITests/RecipeEditingUITests.swift`
- Create: `app/RAWForgeUITests/LibraryAndSettingsUITests.swift`
- Create: `app/RAWForge/UI/Demo/DemoAppEnvironment.swift`
- Modify: `app/RAWForge/UI/DemoSeed.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `RAWForgeUITests` target
- Produces: `RAWFORGE_DEMO_SCENARIO` launch environment
- Consumes: in-memory camera/store/motion adapters, production views and presentation models

- [ ] **Step 1: Add the UI-test target and one failing first-capture test**

```swift
func testFirstLaunchStarterCapturesAndRepeats() {
    let app = XCUIApplication()
    app.launchEnvironment["RAWFORGE_DEMO_SCENARIO"] = "fresh-compatible"
    app.launch()
    XCTAssertTrue(app.buttons["Capture"].waitForExistence(timeout: 3))
    app.buttons["Capture"].tap()
    XCTAssertTrue(app.staticTexts["Take 1 saved"].waitForExistence(timeout: 3))
    app.buttons["Capture Again"].tap()
    XCTAssertTrue(app.staticTexts["Take 2 saved"].waitForExistence(timeout: 3))
}
```

- [ ] **Step 2: Run only the UI target and confirm the scenario adapter is absent**

- [ ] **Step 3: Implement deterministic app dependencies**

`DemoAppEnvironment` is compiled only under DEBUG. It injects fixed capability, Recipe, clock, storage, motion, and capture responses before `ContentView` is constructed. Scenarios include fresh-compatible, two-step, incompatible-sensor, capture-failure, damaged-record, and populated-library. No scenario calls AVFoundation or writes outside a temporary app-container subtree.

- [ ] **Step 4: Add complete workflow UI tests**

Cover first capture/repeat; create/edit/reorder/duplicate Recipe; Burst/Sequential explanation and conditional gap; Adapt a copy; Run/Take browse/export/delete; Privacy & Data; diagnostic sharing; failure ID; and damaged record. Use accessibility identifiers representing intent, never screen coordinates.

- [ ] **Step 5: Add accessibility assertions**

Launch at `UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge`; assert Capture, Recipe blocker, Stop, and result remain hittable. Verify every icon-only control has a label/hint, status text includes a non-color symbol/word, and focus order follows Run → preview → Recipe → cost → Capture → status. Run Accessibility Inspector manually once and record findings in `docs/app-store/accessibility-checklist.md`.

- [ ] **Step 6: Run unit/UI/Release gates and commit**

```bash
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
cd ..
bash app/tools/release-check.sh
```

Expected: unit and UI targets pass; Release scan passes.

```bash
git add app/project.yml app/RAWForgeUITests app/RAWForge/UI/Demo \
  app/RAWForge/UI/DemoSeed.swift .github/workflows/ci.yml \
  docs/app-store/accessibility-checklist.md
git commit -m "test(ui): verify unified workflow and accessibility"
```
