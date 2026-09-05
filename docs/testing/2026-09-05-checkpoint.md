# Recovery, device verification, and Recipe foundation

## Source recovery

A fresh independent clone outside OneDrive was made from the full local Git history and checked against a fresh origin fetch at `5648b24`. The original OneDrive folder and ignored captures were left untouched. All 60 modified/untracked files were archived first. Exact Git blob comparison showed that 59 code/configuration files were already present in history; the remaining report-source.md was retained without importing unrelated content into the source tree.

## Hardware findings

The reference iPhone 15 Pro was reachable over Wi-Fi on iOS 26.6.

- Initial Release suite at `5648b24`: 243 tests, 1 skipped, 13 failed assertions across two cleanup-journal recovery cases. All 16 DeviceCaptureTests and the separate bracket-splitting integration test passed.
- Cleanup recovery failed for a deleted leaf behind an iOS filesystem alias. Resolve the existing parent before appending the absent leaf, retaining root confinement and rejecting dangling/file symlinks.
- The build-stamp check skipped because Xcode processed Info.plist after stamping it. Move stamping after plist generation with an explicit input dependency, and fail the test rather than skip when the stamp is absent.
- Fixes committed as `22e33e1`, independently reviewed, and integrated on the Recipe branch as `c118f3d`.
- Focused Release device regressions: 65 passed, no failures or skips. Includes build identity, cleanup recovery, traversal/symlink safety, and store integration.
- Two subsequent complete device reruns were interrupted by background camera unavailability. The later run backgrounded around the Auto-Lock interval. A new device regression confirmed that the camera harness did not disable the idle timer.
- `91888d6` adds a test-only keep-awake lease to the hardware camera classes, restoring the prior idle-timer state at teardown. RED reproduced the absent safeguard; both focused device regressions passed after the fix.
- Final complete Release device suite at `91888d6`: **271 tests, zero failures, zero skips**, including repeated characterisation and long-Burst checks. The hardware script wrote the successful ledger automatically. This closes automated verification on the reference phone, not the broader multi-device release matrix or future interface acceptance tests.

## Recipe delivery slice

`51e7456` adds Recipe, Step, immutable snapshot, ordered rendering, compatibility results, and explicit adaptation over existing CaptureSet semantics. Burst/Sequential and sensor offsets are preserved. Invalid timing/exposure, Burst gaps, missing sensors, and empty supported series block. Legacy ShotListEntry records remain readable and ordering helpers preserve the new timing fields.

This is the domain foundation, not a new interface or active Recipe persistence. Controllers still consume the existing timing controls until the orchestration slice lands.

- TDD: expected missing-type failures followed by 60 focused simulator tests passing.
- Independent specification and quality review: approved.
- Integrated simulator suite at `c118f3d`: 256 tests, 14 hardware-only skips, zero failures.
- Hardware-fix Debug/Release binary inspection passed. Compliance assertions: 14/14, with negative checker fixtures passing.

## Test safety follow-up

Inspection found that existing AppStorageTests remove the live shot-list/device-profile files, StoreIntegrationTests clear the live shot list, and some controller tests persist it. These behaviors ran on the phone before they were identified; pre-test contents are unknown, so no claim of restoring those values is made. Saved protocol definitions and banked captures are not the targets of those cleanup calls.

`208abad` isolates hosted XCTest storage before startup migration and logging. The Test action opts in explicitly, the app verifies XCTest is loaded, and one fresh private temporary sandbox supplies every store's Documents/Application Support roots. Normal launches retain their existing paths. Missing opt-in, unverified launch, and sandbox creation failures stop before storage access; there is no fallback to user data and no arbitrary path override.

- Read-only RED tests demonstrated that the previous implementation selected live roots.
- Focused Debug and Release simulator checks: 95 passed each, no failures/skips.
- Removing the opt-in from the generated Test action caused the expected early failure before migration I/O.
- Final complete simulator suite at `208abad`: 266 tests, 14 hardware-only skips, zero failures.
- Physical phone isolation checks: 10/10 passed. Its normal Application Support directory was copied before isolation verification, afterward, and after the final complete hardware suite; all three copies were byte-for-byte identical. No new scene captures were requested from the operator.
- Final source review was completed directly after the independent final reviewer hit a usage limit. Recipe foundation and the original iOS recovery/build-stamp fix had already passed independent review. No material integration defect was found in this delivery slice; full independent whole-branch review was not completed.
- Final Debug/Release binary inspection and all 14 compliance assertions passed after storage isolation.

## Next work

1. Deliver the visible simplification next. The installed app still has the old screens; the Recipe foundation is not a UI redesign.
2. Complete the supporting Recipe persistence and automatic Run/Take orchestration as part of that delivery, rather than presenting these intermediate layers as finished UX.
3. Replace the primary flow with Recipe → frame/focus → Capture; Run/Take boundaries become automatic.
4. Replace current navigation with Shoot and Library plus an ordered Step editor. Preserve explicit Burst/Sequential firing and exact controls under progressive disclosure.

The foundation was subsequently merged and pushed to `main` at `62f5b3e`. The first visible workflow delivery followed; see [workflow delivery](2026-09-05-workflow-delivery.md). Git publication and installation on the phone are separate actions.

## Implementation choices

- Keep the old lifecycle controls until the replacement action is connected; move the source-level ban to that integration task. Removing them earlier would break the intermediate app. The cost is retaining those controls for one additional delivery slice.
- Treat the plan's fixture snippets as examples and retain existing validation/storage invariants rather than adding artificial production fixture APIs. The cost is test signatures differing from the illustrative snippets.
