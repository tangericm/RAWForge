# Recipe and Run Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add versioned Recipes, resumable Runs, immutable Recipe snapshots, and one atomic `captureTake` action over the existing verified capture engine.

**Architecture:** Recipe/Step is a facade over `CaptureSet` and `ShotListEntry`; it does not duplicate exposure rendering. `ActiveRunStore` persists only a validated session identifier, while `SessionStore` remains the data owner. `StationController` stays transaction owner and gains one high-level intent plus safe-boundary cancellation.

**Tech Stack:** Swift 5, Swift Concurrency, Foundation `Codable`, existing AVFoundation adapters, XCTest with in-memory station adapters.

**Spec:** `docs/superpowers/specs/2026-09-01-unified-workflow-compliance-design.md`

## Global Constraints

- Complete `2026-09-01-privacy-compliance-foundation.md` first.
- UI/public language follows `CONTEXT.md`; existing durable format identifiers remain stable.
- Burst and Sequential are stored on every Step and never silently interchanged.
- Burst splitting remains Burst; gap applies only to Sequential.
- Missing physical sensors block execution; adaptation always creates a copy.
- Focus remains Take/Pose state and is not stored in a reusable Recipe.
- A Take either banks every Step or leaves no successful partial record or frame.
- Views will call only high-level workflow intents after this plan.
- No new properties are added to `CaptureModel` for Recipe or Run state.

---

### Task 1: Define Recipe, Step, snapshot, and compatibility results

**Files:**
- Create: `app/RAWForge/Recipe/Recipe.swift`
- Create: `app/RAWForge/Recipe/RecipeValidation.swift`
- Modify: `app/RAWForge/Capture/CaptureFlow.swift`
- Create: `app/RAWForgeTests/RecipeTests.swift`
- Create: `app/RAWForgeTests/RecipeValidationTests.swift`

**Interfaces:**
- Produces: `Recipe`, `RecipeStep`, `RecipeSnapshot`
- Produces: `Recipe.renderedEntries() -> [ShotListEntry]`
- Produces: `RecipeValidator.validate(_:against:) -> RecipeValidation`
- Produces: `RecipeValidator.adaptedCopy(of:against:now:) -> RecipeAdaptation`
- Consumes: `CaptureSet`, `ExecutionMode`, `CapabilityReport`, existing rail validation

- [ ] **Step 1: Write model and firing-invariant tests**

```swift
final class RecipeTests: XCTestCase {
    func testRecipeRendersOrderedShotListEntriesWithoutChangingFiring() {
        var burst = CaptureSet.repeated(.init(shutterSeconds: 0.01, iso: 100), count: 16)
        burst.executionMode = .hardwareBracket
        var sequential = CaptureSet.repeated(.init(shutterSeconds: 0.02, iso: 200), count: 3)
        sequential.executionMode = .sequential
        let recipe = Recipe.fixture(steps: [
            RecipeStep(sensor: .wide, captureSet: burst, dwellSeconds: 0, sequentialGapSeconds: nil),
            RecipeStep(sensor: .telephoto, captureSet: sequential, dwellSeconds: 0.2,
                       sequentialGapSeconds: 0.5)
        ])

        let entries = recipe.renderedEntries()
        XCTAssertEqual(entries.map(\.sensor), [.wide, .telephoto])
        XCTAssertEqual(entries.map { $0.captureSet.firing }, [.hardwareBracket, .sequential])
    }

    func testBurstStepRejectsAGapInsteadOfIgnoringIt() {
        XCTAssertThrowsError(try RecipeStep.validated(
            sensor: .wide, captureSet: .fixture(firing: .hardwareBracket),
            dwellSeconds: 0, sequentialGapSeconds: 0.25))
    }

    func testSnapshotIsUnaffectedByLaterDraftEdits() {
        var recipe = Recipe.fixture(name: "Original")
        let snapshot = RecipeSnapshot(recipe)
        recipe.name = "Edited"
        XCTAssertEqual(snapshot.name, "Original")
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm missing-type failures**

Run the simulator suite with only `RecipeTests` and `RecipeValidationTests`. Expected: compilation fails because the Recipe types do not exist.

- [ ] **Step 3: Implement focused value types**

```swift
struct Recipe: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let version: Int
    let createdAt: Date
    var modifiedAt: Date
    var steps: [RecipeStep]
    var note: String?
    let schemaVersion: Int

    func renderedEntries() -> [ShotListEntry] {
        steps.enumerated().map { index, step in
            ShotListEntry(index: index, sensor: step.sensor,
                          captureSet: step.captureSet,
                          dwellSeconds: step.dwellSeconds,
                          minimumGapSeconds: step.sequentialGapSeconds)
        }
    }
}

struct RecipeStep: Codable, Equatable, Identifiable {
    let id: UUID
    var sensor: SensorCapability.Sensor
    var captureSet: CaptureSet
    var dwellSeconds: TimeInterval
    var sequentialGapSeconds: TimeInterval?
}

struct RecipeSnapshot: Codable, Equatable {
    let recipeID: UUID
    let name: String
    let version: Int
    let capturedDefinition: Recipe
}
```

Use a throwing `RecipeStep.validated` factory to reject negative dwell, negative gap, empty sets, and Burst with a non-nil gap. Keep the memberwise initializer internal for decoding only.

Extend `ShotListEntry` with optional Codable fields `dwellSeconds` and `minimumGapSeconds`; legacy entries decode them as zero and nil. Existing global controller dwell/gap values remain only as a migration input until Task 5, where execution reads the Step values from each entry.

- [ ] **Step 4: Implement capability validation and explicit adaptation**

`RecipeValidation` contains ordered `StepResult` values with kept and dropped rungs plus blockers. A missing/unusable sensor is a blocker. A sensor with zero kept rungs is a blocker. Dropped rungs alone are a warning.

`adaptedCopy` removes only already-reported dropped rungs, never changes firing, and refuses to invent a replacement for a missing sensor. It returns a new Recipe with a new UUID, version 1, a suffix using `CapabilityReport.device.modelIdentifier`, and a complete `changes` array for UI review.

- [ ] **Step 5: Run focused and existing exposure tests; commit**

```bash
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:RAWForgeTests/RecipeTests \
  -only-testing:RAWForgeTests/RecipeValidationTests \
  -only-testing:RAWForgeTests/CaptureSetTests \
  -only-testing:RAWForgeTests/EstimateAndValidationTests test
```

Expected: all selected tests pass.

```bash
git add app/RAWForge/Recipe app/RAWForge/Capture/CaptureFlow.swift app/RAWForgeTests/RecipeTests.swift \
  app/RAWForgeTests/RecipeValidationTests.swift
git commit -m "feat(recipe): add versioned capture definitions"
```

---

### Task 2: Persist Recipes and migrate the current shot list

**Files:**
- Create: `app/RAWForge/Recipe/RecipeStore.swift`
- Create: `app/RAWForge/Recipe/SelectedRecipeStore.swift`
- Create: `app/RAWForgeTests/RecipeStoreTests.swift`
- Modify: `app/RAWForge/Capture/StarterCapture.swift`
- Modify: `app/RAWForge/Session/AppStorage.swift`

**Interfaces:**
- Produces: `RecipeStore.all/load/saveVersion/duplicate/archive/delete`
- Produces: `SelectedRecipeStore.load/save/clear`
- Produces: `RecipeStore.migrateShotListIfNeeded(_:now:) -> Recipe?`
- Consumes: `ShotListStore`, `StarterCapture`, Documents ownership rule

- [ ] **Step 1: Write filesystem tests for versioning and migration**

```swift
func testSavingAnEditCreatesVersionTwoWithoutOverwritingVersionOne() throws {
    let store = try RecipeStore(root: temporaryRoot())
    let v1 = try store.create(Recipe.fixture(name: "Ladder"))
    var draft = v1
    draft.steps.append(.fixture())
    let v2 = try store.saveVersion(draft)
    XCTAssertEqual(v2.version, 2)
    XCTAssertEqual(try store.load(id: v1.id, version: 1)?.steps.count, v1.steps.count)
}

func testShotListMigrationPreservesOrderSensorAndFiring() throws {
    let stored = ShotListStore.Stored.fixture(groupedBySensor: false)
    let migrated = try store.migrateShotListIfNeeded(stored, now: fixedDate)
    XCTAssertEqual(migrated?.renderedEntries(), stored.entries)
}

func testEmptyInstallSelectsACompatibleStarter() throws {
    let selected = try store.ensureStarterSelected(report: .oneWideSensor)
    XCTAssertFalse(selected.steps.isEmpty)
    XCTAssertTrue(RecipeValidator.validate(selected, against: .oneWideSensor).canCapture)
}
```

- [ ] **Step 2: Run `RecipeStoreTests` and verify missing-store failures**

- [ ] **Step 3: Implement atomic, versioned storage**

Store Recipes in `Documents/recipes/{recipe UUID}/v0001.json`; write through a sibling temporary file, decode it, then replace. Store archived state in `Documents/recipes/index.json` so a Recipe's immutable version file is never edited for a display-only flag.

`saveVersion` loads the highest existing version and writes exactly `highest + 1`. `duplicate` creates a new UUID/version 1 and appends “Copy” to the display name. `delete` refuses when the selected identifier matches; the caller must select another Recipe first.

Store only `{recipeID, version}` in `AppStorage.supportFile("selected-recipe.json")`. If the selection is missing or unreadable, choose the newest compatible starter and persist it.

- [ ] **Step 4: Implement one-time shot-list migration**

If no Recipe exists and `ShotListStore.load()` returns non-empty entries, create `Recipe(name: "Imported capture", version: 1, steps: ...)`, preserving authored order, sensor, CaptureSet, and firing. Copy controller-level dwell and gap only when the current values are available to the caller; otherwise use zero/nil and do not infer them.

After the Recipe is decoded back successfully and selected, clear `ShotListStore`. A marker `recipe-migration-v1.json` records the imported Recipe ID so a crash cannot duplicate it.

- [ ] **Step 5: Run store tests and commit**

Expected: `RecipeStoreTests`, `StoreIntegrationTests`, and `StarterCaptureTests` pass.

```bash
git add app/RAWForge/Recipe app/RAWForge/Capture/StarterCapture.swift \
  app/RAWForge/Session/AppStorage.swift app/RAWForgeTests/RecipeStoreTests.swift
git commit -m "feat(recipe): persist and migrate recipe library"
```

---

### Task 3: Persist and recover the active Run

**Files:**
- Create: `app/RAWForge/Run/ActiveRunStore.swift`
- Create: `app/RAWForge/Run/RunMetadata.swift`
- Create: `app/RAWForgeTests/ActiveRunStoreTests.swift`
- Modify: `app/RAWForge/Session/SessionStore.swift`
- Modify: `app/RAWForge/Capture/StationController.swift`

**Interfaces:**
- Produces: `ActiveRunStore.activate/validatedSessionID/finish`
- Produces: `RunMetadataStore.load/save`
- Produces: `StationController.resumeRun(_:)`
- Consumes: `SessionStore.loadSession`, `loadStationsDetailed`, current relative timebase

- [ ] **Step 1: Write recovery tests**

```swift
func testValidPointerResumesAndDerivesNextTakeIndex() throws {
    try fixture.writeSession(id: "RUN")
    try fixture.writeTake(index: 1, sessionID: "RUN")
    try fixture.writeTake(index: 2, sessionID: "RUN")
    try store.activate(sessionID: "RUN")
    let recovered = store.recover(using: fixture.sessionStore)
    XCTAssertEqual(recovered, .init(sessionID: "RUN", nextTakeIndex: 3))
}

func testMissingRunClearsPointerAndReturnsWarning() throws {
    try store.activate(sessionID: "gone")
    XCTAssertEqual(store.recover(using: fixture.sessionStore), .invalid("gone"))
    XCTAssertNil(store.pointer())
}
```

- [ ] **Step 2: Run tests and verify missing-store failures**

- [ ] **Step 3: Implement the narrow pointer and mutable metadata sidecar**

`ActiveRunStore` persists only a schema version and session ID in Application Support. Recovery validates the header and detailed station listing, then derives the next index from the maximum banked station index plus one. It never trusts a stored cursor.

`RunMetadata` contains display name and note and lives as `run-metadata.json` inside the session directory. It is mutable presentation metadata; it does not rewrite `SessionRecord`.

Extend `StationPersisting` with `loadSession(_:) -> SessionRecord?` and `loadStationsDetailed(_:) -> (stations: [StationRecord], unreadable: [String])`. The live adapter delegates to `SessionStore`; controller tests implement both calls in memory.

- [ ] **Step 4: Add controller resume without reopening storage**

```swift
func resumeRun(_ recovered: ActiveRunStore.RecoveredRun) throws {
    guard phase == .noSession,
          let loaded = persistence.loadSession(recovered.sessionID) else {
        throw RunRecoveryError.missingSession(recovered.sessionID)
    }
    session = loaded
    stationIndex = recovered.nextTakeIndex - 1
    captureTimebase = CaptureTimebase(segmentID: UUID().uuidString,
                                      originUptime: clock.uptime())
    set(.sessionOpen)
    startFraming()
}
```

A resumed process starts a new capture segment with a new identifier and monotonic origin. Every later Station records that segment identifier and its values remain “seconds since capture segment start.” Never reconstruct a raw origin from wall-clock time.

- [ ] **Step 5: Run active-run, controller, and store tests; commit**

```bash
git add app/RAWForge/Run app/RAWForge/Session/SessionStore.swift \
  app/RAWForge/Capture/StationController.swift app/RAWForgeTests/ActiveRunStoreTests.swift
git commit -m "feat(run): recover the active capture run"
```

---

### Task 4: Embed immutable Recipe snapshots in Takes

**Files:**
- Modify: `app/RAWForge/Session/FrameRecord.swift`
- Modify: `app/RAWForge/Session/SessionStore.swift`
- Create: `app/RAWForgeTests/RecipeSnapshotRecordTests.swift`
- Modify: `app/RAWForgeTests/StoreIntegrationTests.swift`

**Interfaces:**
- Produces: `StationRecord.recipeSnapshot: RecipeSnapshot?`
- Produces: `StationRecord.correlationID: UUID?`
- Consumes: `RecipeSnapshot` from Task 1

- [ ] **Step 1: Write old/new record tests**

```swift
func testCurrentTakeRoundTripsItsCompleteRecipeSnapshot() throws {
    let snapshot = RecipeSnapshot(.fixture(name: "Reflectance"))
    let record = StationRecord.fixture(recipeSnapshot: snapshot)
    let decoded = try roundTrip(record)
    XCTAssertEqual(decoded.recipeSnapshot, snapshot)
}

func testLegacyTakeWithoutARecipeRemainsReadable() throws {
    let decoded = try JSONDecoder.rawforge.decode(StationRecord.self,
                                                  from: Fixture.stationV3WithoutRecipe)
    XCTAssertNil(decoded.recipeSnapshot)
}
```

- [ ] **Step 2: Run tests and confirm missing fields**

- [ ] **Step 3: Add optional schema fields and store them at close**

Add optional `recipeSnapshot` and `correlationID` to `StationRecord` with `decodeIfPresent`. Increment the station schema. `StationController` freezes the selected Recipe at Take declaration and carries that snapshot until close or abort. It never looks up the mutable library copy while capture is active.

- [ ] **Step 4: Verify export and legacy browsing**

Extend `StoreIntegrationTests` to unzip an archive, decode its station record, and compare the snapshot. Keep the existing assertion that the source directory is untouched.

- [ ] **Step 5: Run store/snapshot tests and commit**

```bash
git add app/RAWForge/Session app/RAWForgeTests/RecipeSnapshotRecordTests.swift \
  app/RAWForgeTests/StoreIntegrationTests.swift
git commit -m "feat(records): embed recipe snapshots in takes"
```

---

### Task 5: Add one-action Take capture and safe-boundary stop

**Files:**
- Modify: `app/RAWForge/Capture/StationController.swift`
- Modify: `app/RAWForge/Capture/LiveStationAdapters.swift`
- Modify: `app/RAWForge/Capture/CaptureRig.swift`
- Modify: `app/RAWForge/Capture/CaptureFlow.swift`
- Create: `app/RAWForge/Capture/TakeOutcome.swift`
- Create: `app/RAWForgeTests/TakeOrchestrationTests.swift`

**Interfaces:**
- Produces: `StationController.captureTake(recipe:) async -> TakeOutcome`
- Produces: `StationController.requestStop()`
- Produces: `TakeOutcome.completed/cancelled/blocked/failed`
- Changes: `StationCaptureRequest.shouldStop: @MainActor () -> Bool`
- Consumes: existing declare/begin/close/abort mechanics internally

- [ ] **Step 1: Write complete, failure, repeat, and stop tests**

```swift
func testOneIntentBanksEveryStepAsOneTake() async {
    let h = Harness.successful()
    let outcome = await h.controller.captureTake(recipe: .fixture(stepCount: 3))
    XCTAssertEqual(outcome.kind, .completed)
    XCTAssertEqual(h.capture.requests.count, 3)
    XCTAssertEqual(h.persistence.writtenStations.count, 1)
    XCTAssertEqual(h.persistence.writtenStations[0].brackets.count, 3)
}

func testFailureOnSecondStepDeletesFramesAndBanksNothing() async {
    let h = Harness.failing(onRequest: 2)
    let outcome = await h.controller.captureTake(recipe: .fixture(stepCount: 3))
    XCTAssertEqual(outcome.kind, .failed)
    XCTAssertTrue(h.persistence.writtenStations.isEmpty)
    XCTAssertEqual(h.persistence.deletedStationIndices, [1])
}

func testStopDuringSequentialReturnsAfterOneFrameBoundary() async {
    let h = Harness.stoppingAfterFirstFrame()
    let outcome = await h.controller.captureTake(recipe: .sequential(frameCount: 10))
    XCTAssertEqual(outcome.kind, .cancelled)
    XCTAssertEqual(h.capture.completedFrameCount, 1)
    XCTAssertTrue(h.persistence.writtenStations.isEmpty)
}
```

- [ ] **Step 2: Run orchestration tests and verify missing high-level API**

- [ ] **Step 3: Implement typed outcomes and one transaction loop**

```swift
enum TakeOutcome: Equatable {
    case completed(correlationID: UUID, station: StationRecord)
    case cancelled(correlationID: UUID)
    case blocked(message: String)
    case failed(correlationID: UUID, message: String)
}

func captureTake(recipe: RecipeSnapshot) async -> TakeOutcome {
    let correlationID = UUID()
    guard let report else {
        return .blocked(message: "This iPhone has not finished checking its cameras")
    }
    let validation = RecipeValidator.validate(recipe.capturedDefinition,
                                              against: report)
    guard validation.canCapture else {
        return .blocked(message: validation.blockers.map(\.message).joined(separator: " · "))
    }
    do {
        try ensureRunOpen()
        try beginTake(snapshot: recipe, correlationID: correlationID)
        for step in recipe.capturedDefinition.steps {
            if stopRequested { throw CaptureInterruption.stopRequested }
            try await captureCurrentStep(step)
        }
        return .completed(correlationID: correlationID, station: try bankTake())
    } catch CaptureInterruption.stopRequested {
        abortTake(.abandoned)
        return .cancelled(correlationID: correlationID)
    } catch {
        abortTake(.captureError, detail: String(describing: error))
        return .failed(correlationID: correlationID, message: String(describing: error))
    }
}
```

Move the current bodies into the named private helpers `ensureRunOpen`, `beginTake`, `captureCurrentStep`, `bankTake`, and `abortTake`; do not maintain a second lifecycle implementation. `captureTake` is the only public method that sequences those helpers. Retain low-level methods as internal test seams, not view actions.

`captureCurrentStep` reads `dwellSeconds` and `minimumGapSeconds` from that Step's rendered `ShotListEntry`. Remove `StationController.dwell` and `minimumGap` after `RecipeStore.migrateShotListIfNeeded` has consumed their legacy values. Estimation receives the same per-entry values, so displayed and executed timing cannot diverge.

- [ ] **Step 4: Check cancellation only at camera-safe boundaries**

Add `shouldStop` to the capture request. In Burst, check after each hardware request has returned and its photos have been banked. In Sequential, check after each individual frame write. Throw `CaptureInterruption.stopRequested`; the controller maps only that error to `.cancelled` and maps camera/storage errors to `.failed`.

The button label derives from the active firing: **Stop after current burst** or **Stop after current frame**. A stop never reports completion and always invokes the existing station-frame deletion path.

- [ ] **Step 5: Keep the legacy primary-action API out of views**

Mark `performPrimaryAction`, `openSession`, `declareStation`, `beginNextSet`, and `closeStation` internal. Existing controller tests may call them; `CaptureFlowView` will be removed in the interface plan. Add a source-level test that searches production UI files and fails if any invoke those names.

- [ ] **Step 6: Run controller, orchestration, reliability, and full tests; commit**

Expected: one/multi-Step, repeat, failure, and stop tests pass; the full simulator suite passes.

```bash
git add app/RAWForge/Capture app/RAWForgeTests/TakeOrchestrationTests.swift
git commit -m "feat(capture): execute a recipe as one atomic take"
```

---

### Task 6: Integrate Recipe selection, Run recovery, and startup

**Files:**
- Create: `app/RAWForge/Recipe/RecipeCoordinator.swift`
- Create: `app/RAWForgeTests/RecipeCoordinatorTests.swift`
- Modify: `app/RAWForge/UI/CaptureModel.swift`
- Modify: `app/RAWForge/UI/ContentView.swift`
- Modify: `docs/adr/0002-user-workflow-facade.md`

**Interfaces:**
- Produces: `RecipeCoordinator` as an independent `ObservableObject`
- Produces: selected Recipe, validation, active Run summary, and `capture()` intent
- Consumes: RecipeStore, SelectedRecipeStore, ActiveRunStore, StationController

- [ ] **Step 1: Write coordinator tests with in-memory stores**

```swift
func testBootSelectsStarterAndRecoversRunWithoutCapturing() async {
    let c = CoordinatorHarness.emptyButCompatible()
    await c.coordinator.boot(report: c.report)
    XCTAssertNotNil(c.coordinator.selectedRecipe)
    XCTAssertEqual(c.coordinator.activeRun?.sessionID, "RUN")
    XCTAssertTrue(c.capture.requests.isEmpty)
}

func testCaptureDelegatesExactlyOnceToController() async {
    let c = CoordinatorHarness.ready()
    await c.coordinator.capture()
    XCTAssertEqual(c.station.captureTakeCalls, 1)
}
```

- [ ] **Step 2: Run tests and verify missing coordinator**

- [ ] **Step 3: Implement coordinator without enlarging `CaptureModel`**

`RecipeCoordinator` owns Recipe/selection/run stores and observes `StationController` outcomes. `CaptureModel` constructs it and exposes one immutable reference, matching ADR-0001's composition-root exception; views observe the coordinator directly so published changes are not republished through `CaptureModel`.

Boot order is privacy migration → orphan sweep → capability probe → Recipe migration/selection → active Run recovery → preview. No step captures or characterizes hardware automatically.

- [ ] **Step 4: Add a temporary bridge to the current capture screen**

Until the interface plan replaces it, add one prominent **Capture Recipe** action to the existing capture screen and hide the manual lifecycle controls behind a DEBUG-only section. This keeps `main` usable after orchestration lands. Release users cannot operate the old state machine manually.

- [ ] **Step 5: Run full tests, Release inspection, and commit**

```bash
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
cd ..
bash app/tools/release-check.sh
```

Expected: simulator suite and Release inspection pass.

```bash
git add app/RAWForge/Recipe/RecipeCoordinator.swift \
  app/RAWForgeTests/RecipeCoordinatorTests.swift app/RAWForge/UI \
  docs/adr/0002-user-workflow-facade.md
git commit -m "feat(workflow): coordinate recipes runs and takes"
```
