# Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the unified app into a reproducible App Store/TestFlight release candidate with validated archives, metadata, screenshots, accessibility evidence, and a multi-device hardware gate.

**Architecture:** Extend the existing simulator, Release-binary, and hardware-verification scripts rather than adding a parallel pipeline. Generate a signed archive only after software gates pass; keep upload as an explicit Account Holder action. Version-control every non-secret submission artifact and verification result.

**Tech Stack:** GitHub Actions self-hosted macOS runner, xcodegen, xcodebuild/XCResult, App Store Connect, TestFlight, shell verification scripts, XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-01-unified-workflow-compliance-design.md`

## Global Constraints

- Complete privacy, orchestration, and interface plans first.
- Xcode project remains generated from `app/project.yml` and is never committed.
- Build identity remains UTC `YYMMDDHHmm` plus commit SHA; dirty archives are rejected.
- Release binary contains no DemoSeed or instrument-check implementation.
- Upload/signing credentials, certificates, profiles, API keys, and account data never enter git.
- Public release requires a fetched, working privacy-policy URL and Apple Developer Program membership.
- TestFlight hardware evidence is required for the exact commit submitted.
- Upload and repository-publication actions require explicit user authorization at execution time.

---

### Task 1: Validate a distributable archive, not only simulator Release

**Files:**
- Create: `app/tools/archive-check.sh`
- Modify: `app/tools/preflight-release.sh`
- Modify: `.github/workflows/ci.yml`
- Create: `app/RAWForgeTests/ArchiveConfigurationTests.swift`

**Interfaces:**
- Produces: `bash app/tools/archive-check.sh`
- Produces: unsigned generic-device `.xcarchive` under caller-supplied `ARCHIVE_PATH`
- Consumes: project generation, build stamp, compliance check, Release token scan

- [ ] **Step 1: Write archive configuration tests**

```swift
func testReleaseBundleHasRequiredPrivacyAndExportMetadata() throws {
    XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    XCTAssertNotNil(Bundle.main.url(forResource: "privacy-policy", withExtension: "md"))
    XCTAssertEqual(Bundle.main.infoDictionary?["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.tangericm.rawforge")
}
```

- [ ] **Step 2: Run the focused tests and confirm current bundle assertions**

Expected: tests pass after the compliance plan; this is a regression baseline, not an intentionally failing test.

- [ ] **Step 3: Implement archive creation and inspection**

`archive-check.sh` runs xcodegen, then:

```bash
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" CODE_SIGNING_ALLOWED=NO archive
```

It verifies `Info.plist`, `PrivacyInfo.xcprivacy`, privacy policy, app icon, bundle ID, minimum OS 17.0, iPhone family, build/version/commit, supported portrait orientation, and absence of developer-only symbols. Every absence check has a Debug positive control or a direct bundle-file assertion.

- [ ] **Step 4: Add archive validation to CI and preflight**

CI runs the unsigned archive after simulator tests and compliance. Preflight runs it before the hardware gate. Use `/tmp/rawforge-archive-check/RAWForge.xcarchive`, replacing that one task-specific directory at the start of the job; never target a workspace root or user directory.

- [ ] **Step 5: Run complete software gates and commit**

```bash
bash app/tools/check-compliance.sh
bash app/tools/release-check.sh
ARCHIVE_PATH=/tmp/rawforge-archive-check/RAWForge.xcarchive bash app/tools/archive-check.sh
```

Expected: all three scripts pass.

```bash
git add app/tools/archive-check.sh app/tools/preflight-release.sh \
  .github/workflows/ci.yml app/RAWForgeTests/ArchiveConfigurationTests.swift
git commit -m "ci(release): validate generic device archive"
```

---

### Task 2: Complete version-controlled App Store submission metadata

**Files:**
- Create: `docs/app-store/app-description.md`
- Create: `docs/app-store/keywords.md`
- Create: `docs/app-store/promotional-text.md`
- Modify: `docs/app-store/review-notes.md`
- Create: `docs/app-store/screenshot-plan.md`
- Create: `docs/app-store/testflight-notes.md`
- Create: `docs/app-store/submission-manifest.json`
- Modify: `app/tools/check-compliance.sh`

**Interfaces:**
- Produces: one reviewed metadata bundle for App Store Connect
- Produces: machine-readable `submission-manifest.json`
- Consumes: approved product vocabulary and privacy answers

- [ ] **Step 1: Add a failing metadata-manifest check**

Extend `check-compliance.sh` to require non-empty values for app name, subtitle, description, keywords, support URL, privacy URL, marketing URL, review contact status, demo instructions, export compliance, privacy answer, and screenshot set in `submission-manifest.json`. It must reject `TBD`, `TODO`, localhost, and the PhotonForge URL.

- [ ] **Step 2: Run the checker and verify missing-manifest failure**

- [ ] **Step 3: Write final user-facing metadata**

Use **RAWForge** as app name. The subtitle describes deterministic Bayer RAW Recipes without promising support on every iPhone. The description leads with camera-first capture, then exact exposure series, Burst/Sequential control, multi-sensor Recipes, DNG witnesses, motion/focus evidence, local-only data, and open source. Keywords do not repeat the app name and stay within App Store Connect's 100-character limit.

Review notes state: camera hardware is required for capture; Library/Help remain accessible if Camera is denied; Motion is optional; no account/backend; developer checks are absent in Release; starter capture steps; long Burst splitting; export route; and a support build ID route.

- [ ] **Step 4: Fill the JSON manifest with exact checked values**

```json
{
  "appName": "RAWForge",
  "subtitle": "Deterministic Bayer RAW",
  "bundleID": "com.tangericm.rawforge",
  "primaryCategory": "Photo & Video",
  "descriptionFile": "docs/app-store/app-description.md",
  "keywordsFile": "docs/app-store/keywords.md",
  "promotionalTextFile": "docs/app-store/promotional-text.md",
  "privacyAnswer": "Data Not Collected",
  "tracking": false,
  "encryption": "No non-exempt encryption",
  "supportURL": "https://github.com/tangericm/RAWForge/issues",
  "privacyURL": "https://tangericm.github.io/RAWForge/privacy/",
  "marketingURL": "https://github.com/tangericm/RAWForge",
  "minimumIOS": "17.0",
  "reviewContactStatus": "Configured in App Store Connect; not stored in git",
  "demoInstructionsFile": "docs/app-store/review-notes.md",
  "screenshotSet": "six deterministic iPhone screenshots"
}
```

The checker verifies linked Markdown files and URL syntax. Network fetching of the policy is deferred to preflight because the repository is private until publication.

- [ ] **Step 5: Run compliance and commit**

```bash
bash app/tools/check-compliance.sh
git add docs/app-store app/tools/check-compliance.sh
git commit -m "docs(release): complete app store metadata"
```

---

### Task 3: Generate deterministic screenshots and visual evidence

**Files:**
- Create: `app/RAWForgeUITests/ScreenshotUITests.swift`
- Create: `app/tools/capture-screenshots.sh`
- Create: `docs/app-store/screenshots/.gitkeep`
- Modify: `docs/app-store/screenshot-plan.md`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: Shoot, Recipe editor, Run detail, Take witnesses, This iPhone, and Privacy screenshots
- Consumes: DEBUG deterministic demo environment; screenshots contain no real user data

- [ ] **Step 1: Write screenshot tests with stable names**

```swift
func testCaptureRequiredAppStoreScreens() {
    launch("two-step-ready")
    snapshot("01-shoot-ready")
    app.buttons["Selected Recipe"].tap()
    snapshot("02-recipe-detail")
    openLibraryRun()
    snapshot("03-run-detail")
    openFirstTake()
    snapshot("04-take-witnesses")
}
```

Implement `snapshot` with `XCTAttachment(screenshot:)`, lifetime `.keepAlways`, and a stable attachment name. Additional tests capture This iPhone and Privacy & Data.

- [ ] **Step 2: Run the screenshot target and verify six named attachments**

- [ ] **Step 3: Implement extraction script**

The script runs the screenshot test at iPhone 17 Pro and iPhone 17 Pro Max simulator sizes, writes one `.xcresult` under `/tmp/rawforge-screenshots`, exports PNG attachments through `xcresulttool`, and copies them to `docs/app-store/screenshots/<device>/`. It verifies exactly six expected base names, nonzero dimensions, no duplicate hashes within a device set, and no status/error overlay.

- [ ] **Step 4: Add non-blocking CI screenshot drift evidence**

CI regenerates screenshots and uploads them as an artifact. It does not fail for pixel drift in v1; it fails for missing scenarios, failed UI tests, wrong count, or empty images. Human review remains a release-checklist item.

- [ ] **Step 5: Review at standard and accessibility Dynamic Type; commit**

Capture a second local set at accessibility XXXL for layout review without using those images as App Store screenshots. Record pass/fail and any fixed issue in `screenshot-plan.md`.

```bash
git add app/RAWForgeUITests/ScreenshotUITests.swift app/tools/capture-screenshots.sh \
  docs/app-store/screenshots docs/app-store/screenshot-plan.md .github/workflows/ci.yml
git commit -m "test(release): generate deterministic store screenshots"
```

---

### Task 4: Expand the hardware gate to a supported-device matrix

**Files:**
- Modify: `app/tools/run-hardware-suite.sh`
- Modify: `app/tools/require-hardware-verification.sh`
- Modify: `docs/hardware-verification.json`
- Create: `docs/app-store/hardware-matrix.md`
- Modify: `docs/app-store/release-checklist.md`

**Interfaces:**
- Produces: per-device/per-commit verification entries
- Consumes: DeviceCaptureTests, TestFlight manual workflows, detected CapabilityReport

- [ ] **Step 1: Change verification schema before scripts**

Version 2 records an array:

```json
{
  "schemaVersion": 2,
  "commit": "full commit SHA",
  "devices": [
    {
      "modelIdentifier": "iPhone16,1",
      "iosVersion": "26.6",
      "sensors": ["0.5x", "1x", "tele"],
      "automatedSuitePassed": true,
      "manualChecks": ["preview", "focus-swap-return", "burst-split", "sequential-gap", "export"]
    }
  ]
}
```

`require-hardware-verification.sh` requires the exact commit and three roles: reference Pro, a compatible single/two-sensor model, and a newer Pro. One physical device may satisfy only one role.

- [ ] **Step 2: Write shell fixture tests for exact commit and role coverage**

Create temporary JSON fixtures under a task-specific temporary directory. Assert failure for stale commit, duplicate role assignment, missing manual check, and failed automated suite; assert success for three complete distinct model identifiers.

- [ ] **Step 3: Extend device run output**

`run-hardware-suite.sh` captures model identifier, iOS, available sensors, build ID, suite result, and timestamp automatically. It never marks manual checks complete. After automated success it prints the exact manual checklist and a command that records each checked item for that model.

- [ ] **Step 4: Define the manual matrix**

For each role verify: cold launch, live preview, every offered physical sensor, automatic/point/manual focus where supported, sensor swap and return, 16-frame Burst splitting, Sequential read-back and gap, safe stop, background/foreground, thermal warning simulation, low-storage simulation, Run resume after relaunch, export/open archive, delete, and diagnostic share. Unsupported capability is a passing explicit “not offered” result, not a skipped blank.

- [ ] **Step 5: Run script fixture tests and commit without fabricating device evidence**

Do not edit `docs/hardware-verification.json` with passing devices until those devices actually run. Commit schema/script/checklist changes and leave preflight blocked on missing evidence.

```bash
git add app/tools/run-hardware-suite.sh app/tools/require-hardware-verification.sh \
  docs/app-store/hardware-matrix.md docs/app-store/release-checklist.md
git commit -m "test(hardware): require multi-device release evidence"
```

---

### Task 5: Perform the public-release and TestFlight dry run

**Files:**
- Modify: `README.md`
- Create: `SECURITY.md`
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Modify: `docs/app-store/release-checklist.md`
- Create: `docs/app-store/release-candidate.md`

**Interfaces:**
- Produces: public contributor/support surface
- Produces: signed release-candidate audit record
- Consumes: all prior gates and Apple Developer Program membership

- [ ] **Step 1: Audit the future public repository**

Run secret scanning over full git history with an approved scanner, inspect large tracked objects, verify captures/build products/profiles remain ignored, and confirm issue templates contain no device serial-number request. Record scanner name/version/command and zero unresolved findings in `release-candidate.md`; do not publish if any secret or private capture remains in history.

- [ ] **Step 2: Add contributor and security documents**

README leads with product workflow, supported-device detection, build/test commands, privacy, file formats, architecture links, and current limitations. CONTRIBUTING requires tests, no captures, no credentials, generated-project policy, hardware-evidence honesty, and glossary usage. SECURITY gives a private vulnerability-reporting route that is created before publication. Code of Conduct uses Contributor Covenant 2.1 with the real enforcement contact supplied by the repository owner.

- [ ] **Step 3: Obtain explicit authorization and publish support URLs**

After the owner approves making the repository public, run `gh repo edit tangericm/RAWForge --visibility public` with the required confirmation flag supported by the installed GitHub CLI. Enable GitHub Pages for the privacy policy, then verify with:

```bash
curl --fail --silent --show-error https://tangericm.github.io/RAWForge/privacy/ >/dev/null
curl --fail --silent --show-error https://github.com/tangericm/RAWForge >/dev/null
```

Do not run either publication command without explicit approval in the execution turn.

- [ ] **Step 4: Build and upload one internal TestFlight candidate**

Run `preflight-release.sh` on the exact clean commit after all three hardware roles pass. Archive with automatic signing in Xcode and choose **TestFlight Internal Only**. Upload remains an explicit Account Holder action. Record App Store Connect build number, processing result, installation result, and tester-visible build identity in `release-candidate.md`; store no account identifier or credential.

- [ ] **Step 5: Exercise the installed candidate and close the dry run**

On TestFlight, perform first capture, repeat, edit a two-Step Recipe, focus swap/return, Run resume, export, deletion, privacy policy, diagnostics, and build-ID copy. Compare the installed build ID to the committed candidate. Log every failure as a GitHub issue linked from `release-candidate.md`; no open release-blocker may remain.

- [ ] **Step 6: Commit public docs and candidate record**

```bash
git add README.md SECURITY.md CONTRIBUTING.md CODE_OF_CONDUCT.md \
  docs/app-store/release-checklist.md docs/app-store/release-candidate.md
git commit -m "docs: prepare public rawforge release"
```

Run the complete preflight again after this documentation commit because the hardware evidence and build identity must match the exact submitted commit.
