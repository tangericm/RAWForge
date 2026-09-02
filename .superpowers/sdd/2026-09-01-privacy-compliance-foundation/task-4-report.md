# Task 4 Report: Manifest, permission copy, and privacy-policy artifacts

Date: 2026-09-01

## Status

Implemented and self-reviewed. The intended commit message is `docs(compliance): declare privacy behavior` on parent `bd97db5`.

## TDD evidence

### RED

Only `app/RAWForgeTests/BuildIdentityTests.swift` had been modified when the RED run started.

Command:

```text
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:RAWForgeTests/BuildIdentityTests test
```

Exit: `65` (`** TEST FAILED **`)

Exact suite summary:

```text
Executed 9 tests, with 1 test skipped and 5 failures (1 unexpected)
```

Expected failures observed:

- `testTheBuiltAppUsesTheApprovedPermissionDescriptions` reported both old values: `RAWForge captures Bayer RAW frames to a protocol.` and `RAWForge records device motion alongside each frame.`
- `testThePrivacyManifestDeclaresExactlyTheAPIsTheCodeUses` reported only Disk Space / `E174.1`; System Boot Time / `35F9.1` was absent.
- `testThePrivacyPolicyIsBundledWithTheApp` reported that `privacy-policy.md` was absent from `Bundle.main`.
- `testTheBundledAppStoreAndHostedPrivacyPoliciesAreByteIdentical` threw file-not-found for the not-yet-created bundled policy source. This is the one XCTest failure classified as unexpected; it was the expected missing-artifact RED condition.

### GREEN

The first implementation run established that Xcode copied `privacy-policy.md` into the app and that the new permission assertions passed. It then stalled when the simulator process tried to read the three source files through an absolute host/OneDrive path. That run was deliberately interrupted with exit `75`. The test was corrected to embed the App Store and hosted policy sources as test-bundle resources and compare them with the app-bundle resource, preserving the byte-drift guarantee without simulator access to the host filesystem.

Final focused command:

```text
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:RAWForgeTests/BuildIdentityTests test
```

Exit: `0` (`** TEST SUCCEEDED **`)

Exact suite summary:

```text
Executed 9 tests, with 1 test skipped and 0 failures (0 unexpected)
```

The one skip is the pre-existing build-stamping check when the hosted test app reports placeholder build `1`; all Task 4 assertions ran and passed.

## Manifest and permission assertions

`BuildIdentityTests` now asserts the exact required-reason dictionary:

```text
NSPrivacyAccessedAPICategoryDiskSpace: [E174.1]
NSPrivacyAccessedAPICategorySystemBootTime: [35F9.1]
```

It also asserts `NSPrivacyCollectedDataTypes` is empty, `NSPrivacyTracking` is `false`, both approved permission strings match exactly in the built Info.plist, and `privacy-policy.md` is present in `Bundle.main`.

`plutil -lint app/RAWForge/Resources/PrivacyInfo.xcprivacy` reports `OK`. Parsed output contains exactly the Disk Space and System Boot Time declarations above, an empty collected-data array, `NSPrivacyTracking = false`, and an empty tracking-domains array.

Approved strings asserted in the built app:

- Camera: “RAWForge uses the camera to preview your scene and save the RAW captures you choose to make.”
- Motion: “RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held.”

## Policy byte identity

`cmp` succeeded for the bundled policy against both documentation copies. All three files have SHA-256:

```text
4ac50870571c5f0eeddd272664f4f45b160038a301b9ba731125daff54ffa68f
```

Verified paths:

- `app/RAWForge/Resources/privacy-policy.md`
- `docs/app-store/privacy-policy.md`
- `docs/privacy/index.md`

The automated byte-identity test compares the app-bundle policy with the App Store and hosted sources embedded in the test bundle, so drift in any copy fails `BuildIdentityTests`.

## Files changed

- Modified `app/RAWForge/Resources/PrivacyInfo.xcprivacy` — added System Boot Time / `35F9.1` while preserving Disk Space / `E174.1`, empty collection, and no tracking.
- Modified `app/project.yml` — approved Camera/Motion strings and test-resource bindings for policy identity.
- Modified `app/RAWForgeTests/BuildIdentityTests.swift` — exact manifest, permission, bundled-resource, and byte-identity assertions.
- Created `app/RAWForge/Resources/privacy-policy.md` — bundled policy.
- Created `docs/app-store/privacy-policy.md` — App Store policy source.
- Created `docs/privacy/index.md` — hosted policy source.
- Created `docs/app-store/privacy-answers.md` — Data Not Collected, Tracking: No, reasons, and release-audit condition.
- Created `docs/app-store/review-notes.md` — physical-device starter Recipe and capture flow without external hardware.
- Created `docs/app-store/export-compliance.md` — `ITSAppUsesNonExemptEncryption = false`.
- Created `docs/app-store/supported-devices.md` — iOS 17 floor and dynamic Bayer RAW capability policy.
- Created this required Task 4 report.

No compile-required file outside Task 4 was changed. No GitHub homepage, publication setting, remote service, or other external state was changed.

## Policy and metadata coverage

The policy states the effective date `2026-09-01`; no account; no transmission to RAWForge or third parties; Camera and optional Motion behavior; local Documents and Application Support storage; user-initiated export; session, incomplete-capture, Recipe, log, app, and exported-copy deletion behavior; capture-session iCloud backup exclusion; diagnostic contents and raw-uptime exclusion; no analytics or tracking; and contact through the public issue tracker.

The App Store answers are explicitly conditioned on an audit of the Release binary, dependencies, entitlements, manifest, and network behavior before every submission. Review notes use current UI labels and identify the physical Bayer RAW capability requirement. Supported-device copy does not claim every iPhone supports Bayer RAW.

## Self-review and concerns

Self-review covered scope, secrets, manifest shape, bundle/resource behavior, copy drift, purpose-string exactness, policy truthfulness, current review navigation, export compliance, and dynamic device gating. No actionable correctness, security, performance, or maintainability finding remains.

Release constraints, not Task 4 defects:

- The hosted policy source has been created but not published, and the public URL has not been fetched or verified. Publication is intentionally outside this task.
- Data Not Collected and Tracking: No remain valid only while the audited no-backend/no-account/no-analytics/no-tracking/no-third-party-SDK/no-Photos/no-new-network architecture remains unchanged.
- Bayer RAW capture requires a compatible physical iPhone; simulator coverage proves build metadata and resources, not hardware capture.

## Fix Round 1

### Exact change

Corrected `docs/app-store/review-notes.md` to identify the actual viewfinder status and its exact text.

Replaced:

```text
If the primary action says **No Bayer sensor on this device**, please use a compatible physical iPhone; the message is the intended capability gate rather than a login or connectivity failure.
```

With:

```text
If the viewfinder status says **No Bayer sensor**, please use a compatible physical iPhone.
```

No surrounding review instructions or other artifacts changed.

### Regression command and output

```text
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:RAWForgeTests/BuildIdentityTests test
```

Exit: `0`

```text
Test Suite 'BuildIdentityTests' passed.
Executed 9 tests, with 1 test skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

### Fix SHA

`62b525dfb125f2fb5539bb3d90f112c6766c3f16`
