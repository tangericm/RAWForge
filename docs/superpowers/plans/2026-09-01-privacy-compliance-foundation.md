# Privacy and Compliance Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove raw boot-time values from durable data, migrate existing records safely, correct the privacy manifest and permission copy, and ship an in-app privacy/support surface.

**Architecture:** Keep monotonic clocks for in-memory measurement, but translate every persisted timestamp into seconds relative to a named capture segment. A segment begins when a Run is opened or resumed in one app process, so relaunch never requires reconstructing a monotonic origin. Decode legacy absolute-uptime records only inside a versioned migrator, validate temporary replacements before atomic exchange, and keep DNG payloads untouched. Add a small Help & Settings feature beside `CaptureModel`, not inside it.

**Tech Stack:** Swift 5, Foundation `Codable`, SwiftUI, XCTest, xcodegen, property-list privacy manifest, Markdown policy resources.

**Spec:** `docs/superpowers/specs/2026-09-01-unified-workflow-compliance-design.md`

## Global Constraints

- iOS deployment target remains 17.0 and the app remains iPhone-only.
- Swift language mode remains 5.0 until the AVFoundation delegate boundary is separately migrated.
- No backend, accounts, analytics, tracking, third-party SDK, Photos access, or new network client.
- New records must contain no raw `ProcessInfo.systemUptime` or raw Core Motion timestamp.
- Existing DNG files are never rewritten.
- Unknown record schemas remain untouched and visible as unreadable/newer, never guessed.
- Every metadata replacement is temporary-write, decode-validate, then atomic replace.
- New UI copy uses the glossary in `CONTEXT.md`.
- Release remains dark-only and developer instrument controls remain absent from Release.

---

### Task 1: Define a capture-segment-relative monotonic timebase

**Files:**
- Create: `app/RAWForge/Session/CaptureTimebase.swift`
- Create: `app/RAWForgeTests/CaptureTimebaseTests.swift`

**Interfaces:**
- Produces: `CaptureTimebase.init(segmentID:originUptime:)`
- Produces: `CaptureTimebase.secondsSinceOrigin(_:) -> TimeInterval`
- Produces: `MotionSummary.offsettingWindow(by:) -> MotionSummary`
- Consumes: existing `MotionSummary` value semantics

- [ ] **Step 1: Write the failing timebase tests**

```swift
import XCTest
@testable import RAWForge

final class CaptureTimebaseTests: XCTestCase {
    func testRawUptimeBecomesRunRelativeTime() {
        let timebase = CaptureTimebase(segmentID: "test-segment", originUptime: 1_000)
        XCTAssertEqual(timebase.secondsSinceOrigin(1_003.25), 3.25, accuracy: 0.000_001)
    }

    func testClockSkewBeforeOriginNeverProducesNegativePersistedTime() {
        let timebase = CaptureTimebase(segmentID: "test-segment", originUptime: 100)
        XCTAssertEqual(timebase.secondsSinceOrigin(99.9), 0)
    }

    func testMotionSummaryOffsetsOnlyItsWindow() {
        let original = MotionSummary.fixture(windowStart: 40, windowEnd: 41)
        let shifted = original.offsettingWindow(by: -40)
        XCTAssertEqual(shifted.windowStart, 0)
        XCTAssertEqual(shifted.windowEnd, 1)
        XCTAssertEqual(shifted.gyroP99, original.gyroP99)
    }
}
```

Add the small `MotionSummary.fixture` factory in the test file so production does not gain test-only API.

- [ ] **Step 2: Run the focused tests and confirm the missing-type failure**

Run:

```bash
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:RAWForgeTests/CaptureTimebaseTests test
```

Expected: compilation fails because `CaptureTimebase` and `offsettingWindow(by:)` do not exist.

- [ ] **Step 3: Implement the value type and explicit summary copy**

```swift
import Foundation

struct CaptureTimebase: Equatable {
    static let persistedName = "secondsSinceCaptureSegmentStart"
    let segmentID: String
    let originUptime: TimeInterval

    func secondsSinceOrigin(_ uptime: TimeInterval) -> TimeInterval {
        max(0, uptime - originUptime)
    }
}

extension MotionSummary {
    func offsettingWindow(by offset: TimeInterval) -> MotionSummary {
        MotionSummary(
            windowStart: max(0, windowStart + offset),
            windowEnd: max(0, windowEnd + offset),
            sampleCount: sampleCount,
            effectiveHz: effectiveHz,
            worstGapSeconds: worstGapSeconds,
            gyroP50: gyroP50, gyroP90: gyroP90, gyroP99: gyroP99, gyroMax: gyroMax,
            accelP50: accelP50, accelP90: accelP90, accelP99: accelP99, accelMax: accelMax)
    }
}
```

- [ ] **Step 4: Run the focused tests and commit**

Expected: `CaptureTimebaseTests` passes.

```bash
git add app/RAWForge/Session/CaptureTimebase.swift app/RAWForgeTests/CaptureTimebaseTests.swift
git commit -m "feat(records): add segment-relative timebase"
```

---

### Task 2: Evolve records and convert every live boundary

**Files:**
- Modify: `app/RAWForge/Capture/StationController.swift`
- Modify: `app/RAWForge/Capture/LiveStationAdapters.swift`
- Modify: `app/RAWForge/Capture/MotionRecorder.swift`
- Modify: `app/RAWForge/UI/BenchModel.swift`
- Modify: `app/RAWForge/Session/SessionRecord.swift`
- Modify: `app/RAWForge/Session/FrameRecord.swift`
- Modify: `app/RAWForge/Session/SessionStore.swift`
- Modify: `app/RAWForge/Diagnostics/DebugLog.swift`
- Create: `app/RAWForgeTests/RecordPrivacyTests.swift`
- Modify: `app/RAWForgeTests/StationControllerTests.swift`
- Modify: `app/RAWForgeTests/DeviceCaptureTests.swift`
- Create: `app/RAWForgeTests/DebugLogPrivacyTests.swift`

**Interfaces:**
- Produces: `StationController.captureTimebase: CaptureTimebase?` as private state
- Produces: `StationRecord.captureSegmentID: String?`
- Produces: `StationRecord.monotonicTimebase: String?`
- Produces: `FrameRecord.capturedAtSegmentStartSeconds: TimeInterval`
- Produces: `FrameRecord.deliveredAtSegmentStartSeconds: TimeInterval?`
- Produces: `FrameRecord.latestMotionAtSegmentStartSeconds: TimeInterval?`
- Produces: `MotionSample.secondsSinceSegmentStart: TimeInterval`
- Changes: `StationMotionRecording.start(timebase:)`
- Changes: `StationCaptureRequest.timebase: CaptureTimebase`
- Changes: `SessionStore.open(capability:now:)` no longer accepts or writes raw uptime
- Produces: `DebugLog.Entry.elapsedSinceLaunch: TimeInterval`
- Consumes: `CaptureTimebase` from Task 1

- [ ] **Step 1: Write record-encoding and boundary tests before changing live code**

Create `RecordPrivacyTests`:

```swift
final class RecordPrivacyTests: XCTestCase {
    func testCurrentSessionOmitsBootAnchorAndStationNamesItsSegment() throws {
        let session = SessionRecord.fixture()
        let sessionText = String(decoding: try JSONEncoder.rawforge.encode(session), as: UTF8.self)
        let station = StationRecord.fixture(captureSegmentID: "segment-1")
        let stationText = String(decoding: try JSONEncoder.rawforge.encode(station), as: UTF8.self)
        XCTAssertFalse(sessionText.contains("openedAtUptime"))
        XCTAssertTrue(stationText.contains(CaptureTimebase.persistedName))
        XCTAssertTrue(stationText.contains("segment-1"))
    }

    func testCurrentFrameEncodingContainsOnlyRelativeMonotonicKeys() throws {
        let frame = FrameRecord.fixture(capturedAtSegmentStartSeconds: 2.5)
        let text = String(decoding: try JSONEncoder.rawforge.encode(frame), as: UTF8.self)
        XCTAssertTrue(text.contains("capturedAtSegmentStartSeconds"))
        XCTAssertFalse(text.contains("capturedAtUptime"))
        XCTAssertFalse(text.contains("uptimeAtDelivery"))
        XCTAssertFalse(text.contains("latestMotionTimestamp"))
    }

    func testCurrentMotionSampleNamesItsRelativeDomain() throws {
        let sample = MotionSample(secondsSinceSegmentStart: 1.25,
                                  gx: 1, gy: 2, gz: 3, ax: 4, ay: 5, az: 6)
        let text = String(decoding: try JSONEncoder.rawforge.encode(sample), as: UTF8.self)
        XCTAssertTrue(text.contains("secondsSinceSegmentStart"))
        XCTAssertFalse(text.contains(#""t""#))
    }
}
```

Define `JSONEncoder.rawforge`, `SessionRecord.fixture`, `StationRecord.fixture`, and `FrameRecord.fixture` privately in the test file using the same date strategy as `SessionStore`.

Add to `StationControllerTests`:

```swift
func testBankedFramesAndMotionUseCaptureSegmentRelativeTime() async {
    let h = Harness(startingUptime: 1_000)
    h.controller.report = h.capability
    h.controller.openSession()
    h.controller.addToShotList(.repeated(.init(shutterSeconds: 0.01, iso: 100), count: 1),
                               sensor: .wide)
    h.controller.declareStation()
    await h.controller.beginNextSet()
    h.controller.closeStation()

    let frame = try! XCTUnwrap(h.persistence.writtenStation?.brackets.first?.frames.first)
    XCTAssertLessThan(frame.capturedAtSegmentStartSeconds, 10)
    XCTAssertLessThan(h.persistence.writtenStation?.motion?.windowEnd ?? 100, 10)
}
```

Add `DebugLogPrivacyTests` to assert a formatted line contains `+0.` and does not contain a supplied raw uptime such as `987654.0`. Inject a clock into a package-internal `DebugLog` initializer rather than sleeping.

- [ ] **Step 2: Run the focused tests and verify schema/API failures**

Run `RecordPrivacyTests`, `StationControllerTests`, and `DebugLogPrivacyTests` on the simulator. Expected: compilation fails on the new fields and initializer labels.

- [ ] **Step 3: Change the current record schema explicitly**

Make `SessionRecord.currentSchemaVersion = 5` and remove `openedAtUptime` from current encoding. Make `StationRecord.currentSchemaVersion = 3` and add:

```swift
let captureSegmentID: String?
let monotonicTimebase: String?
```

Current stations initialize both values from `CaptureTimebase`. Replace the three frame uptime fields with:

```swift
let capturedAtSegmentStartSeconds: TimeInterval
let deliveredAtSegmentStartSeconds: TimeInterval?
let latestMotionAtSegmentStartSeconds: TimeInterval?
```

Change `MotionSample` to:

```swift
let secondsSinceSegmentStart: TimeInterval
var t: TimeInterval { secondsSinceSegmentStart }
```

Current encoders write only these names. Legacy schema decoding is intentionally owned by the migrator in Task 3; current decoders reject schema-4/session and schema-2/station payloads until that startup migration runs.

Update `FocusTests.testAFrameRecordedBeforeFocusExistedStillDecodes` to use the current relative timing key while continuing to omit `focus`; legacy timing compatibility is covered as a complete session transaction in Task 3 rather than by decoding an anchorless frame in isolation.

- [ ] **Step 4: Thread one timebase through capture**

At successful Run/session open or resume, capture the raw clock once:

```swift
private var captureTimebase: CaptureTimebase?

private func beginCaptureSegment() -> CaptureTimebase {
    let created = CaptureTimebase(segmentID: UUID().uuidString,
                                  originUptime: clock.uptime())
    captureTimebase = created
    return created
}
```

Call `beginCaptureSegment()` immediately after `persistence.open` succeeds and immediately after a saved Run is resumed. Clear `captureTimebase` when the Run is finished.

Require `captureTimebase` in `beginNextSet`, pass it in `StationCaptureRequest`, and offset every persisted `MotionSummary` window by `-timebase.originUptime`. Change the motion protocol to `start(timebase:)`; `MotionRecorder` stores its origin and emits `MotionSample(secondsSinceSegmentStart:)` from each Core Motion callback.

In `LiveStationCapture`, convert capture and delivery uptime immediately:

```swift
capturedAtSegmentStartSeconds: request.timebase.secondsSinceOrigin(rawCapturedUptime),
deliveredAtSegmentStartSeconds: request.timebase.secondsSinceOrigin(uptimeNow),
latestMotionAtSegmentStartSeconds: motion.latestTimestamp()
```

`latestTimestamp()` now returns the already-relative value. The Bench creates a fresh local `CaptureTimebase` at the start of each diagnostic run.

- [ ] **Step 5: Make diagnostic logs launch-relative**

Give `DebugLog` an injected `uptime: () -> TimeInterval`, set `launchOriginUptime` in `start(device:)`, and construct entries with:

```swift
elapsedSinceLaunch: max(0, uptime() - launchOriginUptime)
```

Format persisted lines as `+12.345s`; do not include a raw uptime column. Keep the existing wall-clock date in the in-memory entry for ordering and display, but diagnostic files export only the formatted relative value.

- [ ] **Step 6: Run all simulator tests and commit**

```bash
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
```

Expected: all simulator tests pass and device-only tests skip for lack of hardware.

```bash
git add app/RAWForge app/RAWForgeTests
git commit -m "fix(privacy): persist only segment-relative timing"
```

---

### Task 3: Migrate legacy metadata atomically and clear unsafe logs

**Files:**
- Create: `app/RAWForge/Session/RecordPrivacyMigrator.swift`
- Create: `app/RAWForgeTests/RecordPrivacyMigratorTests.swift`
- Modify: `app/RAWForge/RAWForgeApp.swift`
- Modify: `app/RAWForge/UI/ContentView.swift`

**Interfaces:**
- Produces: `RecordPrivacyMigrator.migrate(sessionsRoot:logsRoot:markerURL:) -> Report`
- Produces: `RecordPrivacyMigrator.Report` with migrated sessions, removed logs, untouched unknown records, and failures
- Consumes: legacy session `openedAtUptime` as the only trusted offset anchor

- [ ] **Step 1: Write filesystem tests for success, idempotence, rollback, and unknown schemas**

```swift
final class RecordPrivacyMigratorTests: XCTestCase {
    func testLegacySessionAndMotionBecomeRunRelativeWithoutTouchingDNG() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500,
                                                    frameCapture: 503,
                                                    motionTimes: [502.9, 503.1])
        let beforeDNG = try Data(contentsOf: fixture.dngURL)
        let report = RecordPrivacyMigrator.migrate(
            sessionsRoot: fixture.sessionsRoot,
            logsRoot: fixture.logsRoot,
            markerURL: fixture.markerURL)

        XCTAssertEqual(report.migratedSessions, 1)
        XCTAssertEqual(try fixture.currentFrame().capturedAtSegmentStartSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(try fixture.currentMotion().map(\.secondsSinceSegmentStart), [2.9, 3.1])
        XCTAssertEqual(try Data(contentsOf: fixture.dngURL), beforeDNG)
    }

    func testSecondRunIsACompleteNoOp() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500, frameCapture: 503,
                                                    motionTimes: [503])
        _ = RecordPrivacyMigrator.migrate(sessionsRoot: fixture.sessionsRoot,
                                          logsRoot: fixture.logsRoot,
                                          markerURL: fixture.markerURL)
        let firstBytes = try fixture.allMetadataBytes()
        let second = RecordPrivacyMigrator.migrate(sessionsRoot: fixture.sessionsRoot,
                                                   logsRoot: fixture.logsRoot,
                                                   markerURL: fixture.markerURL)
        XCTAssertEqual(second.migratedSessions, 0)
        XCTAssertEqual(try fixture.allMetadataBytes(), firstBytes)
    }

    func testMalformedRecognizedSessionLeavesEveryOriginalByteUntouched() throws {
        let fixture = try MigrationFixture.legacyV4(origin: 500, frameCapture: 503,
                                                    motionTimes: [503])
        try fixture.corruptStationJSON()
        let before = try fixture.allMetadataBytes()
        let report = RecordPrivacyMigrator.migrate(sessionsRoot: fixture.sessionsRoot,
                                                   logsRoot: fixture.logsRoot,
                                                   markerURL: fixture.markerURL)
        XCTAssertEqual(report.migratedSessions, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
    }

    func testUnknownSchemaIsReportedAndUntouched() throws {
        let fixture = try MigrationFixture.unknownSession(schemaVersion: 999)
        let before = try fixture.allMetadataBytes()
        let report = RecordPrivacyMigrator.migrate(sessionsRoot: fixture.sessionsRoot,
                                                   logsRoot: fixture.logsRoot,
                                                   markerURL: fixture.markerURL)
        XCTAssertEqual(report.untouchedUnknownRecords, 1)
        XCTAssertEqual(try fixture.allMetadataBytes(), before)
    }
}
```

Implement each named fixture helper in the test file; do not abbreviate the actual test bodies during execution.

- [ ] **Step 2: Run the migrator tests and confirm the missing-type failure**

Expected: compilation fails because `RecordPrivacyMigrator` is absent.

- [ ] **Step 3: Implement typed legacy DTOs and atomic replacement**

The migrator recognizes session schema 4 and station schema 2 only. It decodes a `LegacySessionV4`, uses `openedAtUptime` as `origin`, and maps:

```swift
relative = max(0, legacyAbsolute - origin)
```

Apply that mapping to frame capture/delivery/latest-motion values, every `MotionSummary.windowStart/windowEnd`, every JSONL motion sample, and the session header. Write each JSON replacement beside the source with a `.privacy-migration` suffix, decode it as the current type, then call `FileManager.replaceItemAt`. Delete temporary files on failure and retain original bytes.

Before changing any file, decode every recognized metadata file in that session and stage every replacement. If one file cannot be converted, replace none of them. Copy every original metadata file to a sibling `.privacy-backup` before the first exchange; if any exchange fails, restore every already-exchanged source from its backup and validate the restored bytes. Remove backups only after all current records decode successfully. This makes the session—not an individual JSON file—the migration transaction.

Use a marker at `AppStorage.supportFile("privacy-migration-v1.json")` containing the successful migration version and one-time user notice state. Unknown schemas are reported and not marked complete.

Delete legacy `.log` files because their freeform uptime values cannot be transformed safely. Do not delete `.running`; `DebugLog` owns that lifecycle marker.

- [ ] **Step 4: Invoke migration before stores or logs are read**

In `RAWForgeApp.init`, run `AppStorage.migrateAll()` and then the privacy migrator before `DebugLog.start`. Publish the returned one-time notice through a small `LaunchNoticeStore` in Application Support; `ContentView` presents:

> Earlier diagnostic logs were cleared so RAWForge no longer retains the phone's boot-time clock. Captures and DNG files were not removed.

The notice has one **OK** action and is not shown again after acknowledgement.

- [ ] **Step 5: Run migrator, store, and full simulator suites; commit**

Expected: all migration tests pass twice in the same test process, all store tests pass, and a full suite passes.

```bash
git add app/RAWForge/Session/RecordPrivacyMigrator.swift \
  app/RAWForgeTests/RecordPrivacyMigratorTests.swift app/RAWForge/RAWForgeApp.swift \
  app/RAWForge/UI/ContentView.swift
git commit -m "feat(privacy): migrate legacy timing records"
```

---

### Task 4: Correct manifest, permission copy, and privacy-policy artifacts

**Files:**
- Modify: `app/RAWForge/Resources/PrivacyInfo.xcprivacy`
- Modify: `app/project.yml`
- Modify: `app/RAWForgeTests/BuildIdentityTests.swift`
- Create: `app/RAWForge/Resources/privacy-policy.md`
- Create: `docs/app-store/privacy-policy.md`
- Create: `docs/privacy/index.md`
- Create: `docs/app-store/privacy-answers.md`
- Create: `docs/app-store/review-notes.md`
- Create: `docs/app-store/export-compliance.md`
- Create: `docs/app-store/supported-devices.md`

**Interfaces:**
- Produces: bundled privacy-policy resource
- Produces: manifest reasons `E174.1` and `35F9.1`
- Changes: Camera and Motion purpose strings to approved copy

- [ ] **Step 1: Update the manifest test before the manifest**

Replace the single-entry assertion with a dictionary comparison:

```swift
let declared = Dictionary(uniqueKeysWithValues: apis.map {
    ($0["NSPrivacyAccessedAPIType"] as! String,
     $0["NSPrivacyAccessedAPITypeReasons"] as! [String])
})
XCTAssertEqual(declared, [
    "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
])
```

Add assertions for the exact Camera and Motion strings from the spec and for `privacy-policy.md` being present in `Bundle.main`.

- [ ] **Step 2: Run `BuildIdentityTests` and verify all three assertions fail**

Expected: manifest count, purpose strings, and missing resource fail.

- [ ] **Step 3: Update release metadata**

Set the two `project.yml` values exactly:

```yaml
NSCameraUsageDescription: "RAWForge uses the camera to preview your scene and save the RAW captures you choose to make."
NSMotionUsageDescription: "RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held."
```

Add System Boot Time / `35F9.1` beside Disk Space / `E174.1` in `PrivacyInfo.xcprivacy`. Keep collected data empty and tracking false.

- [ ] **Step 4: Write one policy in three verified locations**

The policy states: no account; no data transmission to RAWForge or third parties; Camera and optional Motion use; local Documents/Application Support locations; user-initiated export; deletion behavior; iCloud backup exclusions for captures; diagnostics contents; no analytics/tracking; contact through the public issue tracker; effective date 2026-09-01.

Copy the exact Markdown to all three listed files. Add a test that compares their bytes so the bundled, App Store, and GitHub Pages sources cannot drift.

Write `privacy-answers.md` with **Data Not Collected**, **Tracking: No**, and the audited reasons. Write concrete review notes describing how to select the starter Recipe and capture without external hardware. Record `ITSAppUsesNonExemptEncryption = false` in `export-compliance.md`. State the dynamic capability policy and iOS 17 floor in `supported-devices.md`; do not claim every iPhone supports Bayer RAW.

- [ ] **Step 5: Run tests and commit**

```bash
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:RAWForgeTests/BuildIdentityTests test
```

Expected: all `BuildIdentityTests` pass.

```bash
git add app/project.yml app/RAWForge/Resources app/RAWForgeTests/BuildIdentityTests.swift docs/app-store
git commit -m "docs(compliance): declare privacy behavior"
```

---

### Task 5: Add the release-safe Help & Settings compliance surface

**Files:**
- Create: `app/RAWForge/UI/HelpSettingsView.swift`
- Create: `app/RAWForge/UI/PrivacyDataView.swift`
- Create: `app/RAWForge/UI/AboutView.swift`
- Modify: `app/RAWForge/UI/ContentView.swift`
- Create: `app/RAWForgeTests/CompliancePresentationTests.swift`

**Interfaces:**
- Produces: `HelpSettingsView(report: CapabilityReport?)`
- Produces: `PrivacyDataView()` and `AboutView(identity:)`
- Consumes: `DeviceIdentity.current()`, bundled privacy policy, `SessionStore`, `DebugLog`

- [ ] **Step 1: Write presentation tests for truthful copy and links**

Extract non-visual content into:

```swift
struct CompliancePresentation {
    static let privacySummary = "Captures and diagnostics stay on this iPhone until you choose to export them."
    static let sourceURL = URL(string: "https://github.com/tangericm/RAWForge")!
    static let policyURL = URL(string: "https://tangericm.github.io/RAWForge/privacy/")!
}
```

Test the exact URLs, summary, permission descriptions, Data Not Collected wording, Apache-2.0 label, and build description.

- [ ] **Step 2: Run the focused tests and verify the missing presentation type**

Expected: compilation fails on `CompliancePresentation`.

- [ ] **Step 3: Build the settings hierarchy**

`HelpSettingsView` is a `List` with NavigationLinks for Privacy & Data, This iPhone, Diagnostics, Support, and Open Source & About. In this phase:

- Privacy & Data renders the bundled policy, Camera/Motion use, storage/export/deletion, and on-device summary.
- This iPhone routes to the existing capability and Device profile views.
- Diagnostics routes to existing logs and diagnostic sharing, without `InstrumentChecksView` in Release.
- Support offers Copy Build ID and opens documentation/source links.
- About shows version, build, commit, device identifier, iOS, and Apache-2.0.

Add a gear toolbar button to both current Capture and Sessions roots. The later navigation plan will retain the same view when tabs become Shoot and Library.

- [ ] **Step 4: Run simulator tests and Release binary inspection**

```bash
cd app
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
cd ..
bash app/tools/release-check.sh
```

Expected: all tests pass; Release contains `HelpSettingsView` and still excludes every developer-only positive-control token.

- [ ] **Step 5: Correct repository metadata and commit**

Run:

```bash
gh repo edit tangericm/RAWForge --homepage "https://tangericm.github.io/RAWForge/privacy/"
gh repo view tangericm/RAWForge --json homepageUrl --jq .homepageUrl
```

Expected output: `https://tangericm.github.io/RAWForge/privacy/`. If GitHub Pages is not published yet, use `https://github.com/tangericm/RAWForge` temporarily and record the hosted-policy URL as a release gate; never leave the PhotonForge URL.

```bash
git add app/RAWForge/UI app/RAWForgeTests/CompliancePresentationTests.swift
git commit -m "feat(compliance): add privacy and support settings"
```

---

### Task 6: Add a machine-enforced compliance gate

**Files:**
- Create: `app/tools/check-compliance.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `app/tools/preflight-release.sh`
- Create: `docs/app-store/release-checklist.md`

**Interfaces:**
- Produces: `bash app/tools/check-compliance.sh`
- Consumes: built app bundle, source scan, privacy manifest, policy files, purpose strings

- [ ] **Step 1: Write the checker with positive controls**

The script must fail unless all of these are true:

```text
source contains ProcessInfo.processInfo.systemUptime (positive control)
durable record source contains capturedAtSegmentStartSeconds
durable record source does not declare capturedAtUptime or uptimeAtDelivery
privacy manifest contains E174.1 and 35F9.1
bundled, App Store, and docs/privacy policy files are byte-identical
project.yml contains both approved purpose strings
App Store privacy answers say Data Not Collected and Tracking: No
repository contains LICENSE with Apache License, Version 2.0
```

Use fixed-string searches and `cmp`; print one labelled result per assertion. The raw uptime source positive control matters because in-memory use is expected—an empty search must not be misreported as proof that the manifest is unnecessary.

- [ ] **Step 2: Deliberately break one copied policy in a temporary worktree and verify failure**

Create the execution worktree through `superpowers:using-git-worktrees`, append one line to its bundled policy, run the checker, and expect a non-zero exit naming policy drift. Restore the file through a patch, rerun, and expect success. Do not perform this destructive-control test in the main checkout.

- [ ] **Step 3: Wire the checker into CI and preflight**

Add it after the simulator suite and before the Release build in CI. Add it as a new numbered section before the hardware gate in `preflight-release.sh`, updating the displayed denominator.

- [ ] **Step 4: Write the release checklist**

The checklist has explicit boxes for clean tree, simulator suite, compliance checker, Release binary scan, archive validation, privacy-policy URL fetch, App Store privacy answers, purpose strings, export compliance, screenshots, review notes, hardware verification matrix, and manual upload approval.

- [ ] **Step 5: Run the complete software gate and commit**

```bash
bash app/tools/check-compliance.sh
cd app && xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
cd ..
bash app/tools/release-check.sh
```

Expected: compliance passes, simulator suite passes, and Release inspection passes.

```bash
git add app/tools/check-compliance.sh .github/workflows/ci.yml \
  app/tools/preflight-release.sh docs/app-store/release-checklist.md
git commit -m "ci: enforce privacy and compliance contract"
```

---

### Task 7: Close the two final privacy-review residuals

**Authorized:** 2026-09-02

**Files:**
- Modify: `app/RAWForge/RAWForgeApp.swift`
- Modify: `app/RAWForge/Session/LaunchStorageMaintenance.swift`
- Modify: `app/RAWForge/Session/RecordPrivacyMigrator.swift`
- Modify: `app/RAWForgeTests/RecordPrivacyMigratorTests.swift`
- Modify other directly covering tests only when the behavior requires it

**Interfaces:**
- Consumes: `LaunchStorageMaintenance.Report.orphanedFramesRemoved`
- Produces: launch notice copy that distinguishes privacy migration from orphan cleanup
- Consumes: unversioned schema-3-era `DarkSettingRecord` JSON containing `photoTimestampSeconds`
- Produces: current dark-setting JSON containing only `photoTimestampAtSegmentStartSeconds`

- [ ] **Step 1: Write and run the failing combined-launch notice test**

Exercise the real launch-maintenance and notice boundary where privacy migration succeeds
and true orphan cleanup removes at least one DNG in the same launch. The visible notice
must not say that no DNG was removed. Preserve the truthful no-removal copy when the sweep
removed nothing. Run the focused test and capture the expected RED failure before changing
production code.

- [ ] **Step 2: Write and run failing dark-calibration migration tests**

Create a hand-authored unversioned dark-setting fixture from the schema-3 era with a
non-nil absolute `photoTimestampSeconds`. With a session anchor, migration must replace
the old key with the hand-derived segment-relative value while preserving DNG and motion
bytes. Without an anchor, migration must fail safely and preserve metadata and payload
bytes. Run both tests and capture the expected RED failures before implementation.

- [ ] **Step 3: Implement the narrowest compatibility-safe fixes**

Thread the orphan-removal outcome into the launch notice without duplicating sheet or
startup ownership. Detect the legacy dark-frame key before current decoding can ignore it;
convert it only with a valid anchor, remove the old key, and preserve idempotence and
transactional behavior.

- [ ] **Step 4: Run focused and complete software gates**

```bash
cd app
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
cd ..
bash app/tools/check-compliance.sh
bash app/tools/release-check.sh
```

Expected: focused regressions and full simulator suite pass, compliance passes, Release
inspection passes, `git diff --check` is clean, and no hardware or external publication
is performed.
