# Interface refinement and automated UI checks

## What changed

Impeccable's distill/native-iOS guidance and Taste's existing-product audit informed a scoped refinement, not a new visual identity. RAWForge remains dark, uses semantic system colors, Dynamic Type and SF Symbols, and retains Burst/Sequential and exact exposure controls.

- Shoot has a labelled Edit action instead of an unexplained icon.
- Recipe rows have visible options for editing/duplication, replacing the separate selected-Recipe edit row. Long-press options remain available.
- Ordered Steps show camera, firing, frame count and camera-adjusted shutter/ISO ranges. Multi-frame blocks show proportional shutter bars, explicitly limiting long displays to the first 24 frames. Invalid drafts display a correction message instead of formatting nonfinite values.
- Reorder sits beside the Steps heading, or below it at accessibility sizes, rather than in a detached bottom toolbar.
- The entire Add Step row is tappable.
- Switching to Burst with an authored interval uses a native alert with explicit keep/remove actions. The previous confirmation popover omitted its cancel action in the tested environment.

No capture semantics, persistence schema, or saved records changed in this slice.

## Test boundaries

`RAWForgeUI` is a separate Debug XCUITest scheme. It does not add UI tests or UI launch flags to the existing hardware scheme. Each UI launch opts into a fresh private temporary app-container subtree **before** migration, logging or any store access. Support is compiled only into the Debug simulator path; malformed or unsupported flags fail closed. Hosted unit tests still require their independent XCTest-runtime and storage-opt-in checks. Normal app roots do not change.

Tests exercise real SwiftUI screens and real Recipe storage with demo sensor capabilities, not synthetic success labels. No UI test in this slice presses Capture or claims to verify RAW output.

The UI scenarios cover:

1. Shoot/Library navigation and access to Privacy & Data without opening a Run.
2. Saving edits as another version and cancelling a subsequent draft.
3. Sequential-only interval and explicit confirmation before Burst removes it.
4. Capture/Edit/Save/Cancel reachability at the largest Dynamic Type category.
5. Adding a 16-frame repeat, preserving Step order and updating the total to 17 frames.

CI runs the separate UI scheme and retains its result bundle and screenshots. Local runs use the dedicated RAWForge-Isolation-Verification simulator. The phone and original OneDrive checkout were not used or changed in this slice.

## Evidence

Expected failures were observed before implementing the UI-launch storage gate and Step presentation. The first editor test failed on the missing Edit Recipe action. The first full UI run exposed the absent Keep Sequential action; the later Add Step test exposed the row's inactive centre. Both unchanged interaction tests passed after the scoped fixes.

Final Debug simulator verification: **311 tests, 15 hardware tests skipped, zero failures**, plus **5 UI tests with zero failures**. The Debug/Release binary check passed with developer-only code absent from Release and positive controls present. The compliance checker passed all 14 assertions and both negative fixtures. These are local results; the new CI job has not run remotely yet.

A focused Release-configuration run also passed **19 storage/summary tests**, including compiled rejection of the UI launch flag. The initial invocation could not compile `@testable import` because shipping Release disables testability; the successful test-only invocation used `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`. No shipping build settings changed, and this instrumented test build is distinct from the unmodified Release binary check.

The final Shoot, two-Step editor and largest-text editor screenshots were visually inspected and are included in the walkthrough. The mechanical Impeccable detector returned no findings for the three changed SwiftUI views; that is not a substitute for native UI tests or visual inspection. An independent task/integration reviewer approved the scoped changes; complete camera/stop/export/recovery UI coverage and full accessibility certification remain outstanding. The added ordering test verifies append order, not drag-to-reorder persistence.

## Reproduce

```sh
cd app
xcodegen generate
xcodebuild -project RAWForge.xcodeproj -scheme RAWForgeUI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
```

See the [visual walkthrough](../design/20260905-interface-refinement.html). Images are simulator renders, not phone captures or generated mockups.
