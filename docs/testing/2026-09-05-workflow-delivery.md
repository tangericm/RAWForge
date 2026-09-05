# First visible Recipe workflow delivery

## User-visible changes

- Shoot and Library replace the four primary tabs in both build configurations. Help & Settings remains at the gear button. Debug Console/Bench moved under Development in settings; Release diagnostics remain under Diagnostics.
- Shoot selects the saved Recipe, shows its cameras, firing, frame count and approximate time/storage, and executes all Steps with one Capture action. It opens/resumes a Run automatically. Finish Run ends only the bookmark, not saved files.
- Recipe editing is an ordered Step list with native move/delete controls. Steps retain explicit Burst/Sequential, exact shutter/ISO values, per-camera offsets, dwell and Sequential-only intervals. Generating a repeat/ladder is explicit; saving creates another immutable version.
- Existing protocols remain available as Step sources and under Advanced library tools. The existing capture browser, witnesses, thumbnails, export and Run deletion are retained. The current Run cannot be deleted through that browser until finished.
- Unsupported frames are listed before adaptation; adaptation saves a new copy. Missing cameras block capture instead of being substituted.
- Focus continues through the existing per-camera sheet. It is not a Recipe field and is not a mandatory workflow step.

## Persistence and transaction behavior

Recipe versions live in Documents/recipes. A bookmark selects an exact version. Migration writes a recoverable intent before the imported Recipe, persists selection before clearing the legacy draft, and retries the same identity after interruption. Recipes with unsupported schemas are not silently rewritten.

Active Run recovery validates headers, scene type, record identity and filenames, then derives the next index from banked records. It starts a fresh relative time segment. Capture revalidates existing Runs before changing the bookmark or requesting camera work. Calibration no longer substitutes its session for a scene Run.

Take records now use station schema 5 with an embedded Recipe snapshot and diagnostic correlation UUID. Privacy-safe schema 4 stays readable without a rewrite or invented Recipe identity. Older unsafe schemas still go through the existing privacy migration. Downgrading to an older binary will not make new schema-5 records readable there; preserve them and return to the newer app. No destructive schema contraction is performed.

One high-level controller intent reuses the existing declare/begin/close/abort transaction. Each Step supplies its own timing. Burst remains Burst across request splits. Stop is checked before and after waits and after completed banking boundaries; an already-running camera response is allowed to finish. A failed Take record write aborts the Take. Station records are staged, decoded and atomically published without replacing an existing file; frame writes also refuse replacement.

## Verification

- Foundation merged and pushed first at `62f5b3e`; merged-tree simulator gate: 268 tests, 15 hardware skips, zero failures.
- Recipe storage `f42bfe0`: expected missing-store RED, then 34 selected storage/starter tests passed.
- Run recovery/snapshot integration: 288 simulator tests, 15 hardware skips, zero failures.
- Full workflow and regression gates: 302 simulator tests, 15 hardware skips, zero failures. Includes real-filesystem versioning/import/slot/publication checks, full Recipe transaction through a fake camera, real-header repeat capture, and stop-boundary simulation. The simulator does not validate live AVFoundation performance.
- Targeted independent backend review found five issues: filename/index mismatch, stop during a wait, partial station publication, stale/calibration Run reuse, and same-second Run creation collision. Regression tests reproduced these; fixes retain exclusive writes and received bounded source-level confirmation. A separate real-header test caught and fixed transient-versus-serialized date precision during repeat capture.
- Source review is not a full independent interface audit. The new UI was checked with simulator screenshots, including large Dynamic Type. The first screen inspection found the floating tab bar obscuring Capture; the action is now pinned above it and the preview constrained to the available space.
- Debug and Release builds passed. Forbidden-symbol checks passed with positive controls: developer-only probes and demo screens are absent from Release. All 14 compliance assertions and both negative checker fixtures passed.
- The previous 271/0-skip hardware result at `91888d6` applies to the foundation only. No new phone installation or hardware verification was performed for this workflow delivery. No operator scene captures were requested.

## Deliberate scope limits and next work

This ships the usable core interaction rather than presenting foundation-only work as a finished redesign. It is not the full interface plan or an App Store readiness claim.

1. Add deterministic XCUITest scenarios and presentation-state tests for the new screens; screenshots and controller tests are not substitutes for end-to-end UI coverage.
2. Consolidate Step presentation, add graphical exposure/timing breakdowns, search/import/version-history and richer Run/Take summaries. Wire Run naming/notes and Recipe archive/delete controls to the implemented stores.
3. Make Library available when camera permission is denied, integrate direct preview tap-to-focus and explicit repeated-Take focus retention, and improve result/detail/diagnostic-ID routing.
4. Add the planned archive-unzip/snapshot comparison and complete the record-view parity checklist before retiring old UI files. Export currently uses the existing whole-directory archive path; typed snapshot round trips and source-preservation tests pass.
5. Retire legacy lifecycle UI/test seams only after that parity check. New primary screens call workflow intents; old internal entry points and their timing defaults are temporarily retained for compatibility and diagnostics, not used by Recipe execution.
6. Install the new build on the phone separately, then verify real preview, multi-Step capture and stop responsiveness. The hardware ledger must not be updated from simulator evidence.

Screenshots are real simulator renders, not phone captures or generated mockups: [Shoot](../design/screenshots/20260905-shoot.png), [Recipe editor](../design/screenshots/20260905-recipe-editor.png), [large text](../design/screenshots/20260905-shoot-large-text.png).
