# Unified workflow and compliance design

**Date:** 2026-09-01

**Status:** proposed for implementation

**Research:** [A simpler RAWForge without making it less rigorous](../../research/unified-workflow-and-compliance.md)

**Domain language:** [CONTEXT.md](../../../CONTEXT.md)

**Architecture decision:** [ADR-0002](../../adr/0002-user-workflow-facade.md)

## 1. Product statement

RAWForge should feel like a camera while it is being used and like a scientific instrument
when its output is inspected. A person chooses a Recipe, frames and focuses the scene, and
presses Capture. RAWForge automatically creates the record boundaries needed to make the
result atomic, reproducible, and diagnosable.

The interface must make the common path obvious without hiding the distinction between
Burst and Sequential firing, removing exact controls, or weakening the capture record.

## 2. Goals

1. Reduce the primary workflow to **choose a Recipe → frame and focus → Capture**.
2. Replace visible Plan/Protocol/Shot list/Set/Session/Station terminology with the
   Recipe/Step/Run/Take language in [CONTEXT.md](../../../CONTEXT.md).
3. Execute every Step from one Capture action while preserving all-or-nothing Take banking.
4. Keep every expert control and recorded witness reachable within two disclosure levels.
5. Make compatibility, time, storage, thermal state, motion state, and failures legible
   before or immediately after capture.
6. Put privacy, permissions, device support, diagnostics, source, and support in one place.
7. Correct the required-reason API and uptime record before App Store submission.
8. Preserve existing saved definitions and captures without silently changing their
   meaning.

## 3. Non-goals

- A new camera or persistence engine.
- A node-and-wire programming canvas.
- Accounts, synchronization, analytics, telemetry, or a backend.
- Automatic substitution of one physical sensor for another.
- Hiding or merging Burst and Sequential semantics.
- Requiring calibration or device-characterisation runs before normal capture.
- Renaming every existing Swift type or durable format identifier in the first release.
- A separate “Quick mode” with different capture behavior.

## 4. Canonical language

All new interface copy, onboarding, help, accessibility labels, and public documentation
use Recipe, Step, Run, Take, Pose, Frame, Witness, Device profile, and Calibration exactly
as defined in [CONTEXT.md](../../../CONTEXT.md).

Implementation and migration code may retain existing names where changing them adds risk.
Those names must not leak into primary interface copy. Diagnostic exports may include both
the user term and stable format identifier when that helps support correlate a record with
source code.

## 5. Information architecture

RAWForge has two top-level tabs.

### 5.1 Shoot

The Shoot screen contains, from top to bottom:

1. a compact active-Run chip;
2. the live preview with focus feedback;
3. the selected Recipe card;
4. the Recipe's frame, duration, and storage estimate;
5. one primary Capture control;
6. compact storage, thermal, motion, and compatibility status; and
7. contextual progress or the most recent result.

The screen answers one question at a glance: **what will happen if I press Capture?**

The active-Run chip opens naming, notes, summary, and Finish Run. It is not a prerequisite
dialog. The Recipe card opens selection or editing. The estimate opens the detailed
timeline and overhead breakdown.

### 5.2 Library

Library has two visible sections in one navigation hierarchy rather than additional
top-level tabs:

- **Recipes** — search, select, create, duplicate, edit, archive, import, and export;
- **Captures** — browse Runs and Takes, inspect witnesses, share, export, and delete.

A segmented control or section picker may switch between Recipes and Captures. Navigation
depth, not parallel tab bars, reveals Recipe versions, Run contents, and Take details.

### 5.3 Help & Settings

A consistently placed Help & Settings button is available from both top-level roots. It
contains:

- Privacy & Data;
- This iPhone;
- Diagnostics;
- Support; and
- Open Source & About.

Console and Bench are not release tabs. Their useful capabilities move into Diagnostics
and This iPhone. Development-only instrument checks remain excluded from Release builds.

## 6. Recipe model

### 6.1 Recipe

A Recipe owns:

- a stable identifier;
- display name;
- schema version and user-facing version;
- creation and modification dates;
- an ordered, non-empty array of Steps; and
- an optional note.

Saving edits creates a new Recipe version. A Take embeds the complete immutable Recipe
snapshot that produced it. Editing or deleting the library copy never mutates a past Take.

### 6.2 Step

A Step owns:

- a stable identifier and order;
- physical sensor role;
- an Exposure Series: Single, Repeat, or Exposure ladder;
- exact shutter and ISO specifications;
- Burst or Sequential firing;
- optional per-sensor exposure offset;
- optional pre-capture dwell;
- optional Sequential-only inter-frame gap.

Existing `CaptureSet`, `CaptureSpec`, generator, validation, and `ExecutionMode` semantics
remain the execution source of truth. Recipe/Step is an orchestration and presentation
layer, not a parallel definition of exposure math.

### 6.3 Firing invariants

- Firing is stored on every Step and always visible in its collapsed summary.
- Burst may split a long series into multiple hardware requests but remains Burst.
- RAWForge never silently converts Burst to Sequential.
- Burst fires each hardware request as quickly as possible and does not show a gap control.
- Sequential requests frames individually and may show an inter-frame gap.
- The editor explains that Sequential provides per-frame camera read-back while Burst does
  not provide equivalent achieved exposure read-back.

### 6.4 Compatibility

Recipe validation runs against the current Device profile before capture and whenever a
Step changes. Each Step displays one of:

- compatible;
- compatible with explicitly listed dropped rungs; or
- blocked, with the missing capability named.

If a required sensor is unavailable, Capture is blocked. RAWForge offers **Adapt a copy for
this iPhone**, which previews each proposed change and creates a new Recipe. It never
substitutes a sensor or removes a rung in the original Recipe.

Dropped rungs remain recorded exactly as they are today. The user sees the count and can
inspect each requested value and reason before capture.

### 6.5 Existing protocols

The existing protocol library remains readable. Its definitions appear under **Add from
existing** when building a Step and can be promoted into Recipes. The existing shot list is
treated as the initial current Recipe during migration. No saved definition is deleted by
this redesign.

## 7. Run and Take lifecycle

### 7.1 Active Run

The first Capture action creates a Run if no valid active Run exists. A small active-Run
pointer in Application Support survives relaunch. On launch RAWForge:

1. validates that the referenced Run exists and is readable;
2. resumes it if valid;
3. derives the next Take index from banked records; and
4. clears the pointer and reports a recoverable warning if invalid.

Finish Run clears the active pointer. It does not rewrite an immutable Run header. The next
Capture creates a new Run. Naming or adding a Run note is optional and never blocks capture.

### 7.2 One Capture action

Capture asks one orchestration boundary to:

1. create or resume the Run;
2. snapshot and validate the selected Recipe;
3. open a pending Take;
4. execute every Step in order;
5. bank all frames and the complete Take record; or
6. remove the pending Take and its files after any hard fault.

Views do not call open-session, declare-station, begin-next-set, close-station, or abort-
station methods individually.

The outcome is typed as completed, cancelled, blocked, or failed. Each outcome carries a
human-readable summary and a diagnostic correlation identifier.

### 7.3 Cancellation

While capture is active, the primary control becomes **Stop after current burst** during a
Burst request or **Stop after current frame** during Sequential firing. A stop request is
observed only at that camera-safe boundary, after any current file write has completed. The
pending Take is then aborted atomically. The interface never implies that AVFoundation work
already in flight can be interrupted safely.

### 7.4 Repetition

After a completed, cancelled, or failed Take, the interface returns to the selected Recipe
and current framing. Repeating an unchanged Recipe requires one Capture press. The latest
result remains available without covering the preview.

## 8. Focus workflow

Focus is Take-level intent tied to the current subject and Pose, not part of a reusable
Recipe. Default behavior auto-acquires and then locks independently for each sensor used by
the Take. A sensor swap acquires focus on the new sensor because actuator positions are not
transferable between camera modules. Returning to a sensor restores that sensor's own
achieved position for the remainder of the Take where the device supports it.

Tap-to-focus stores a normalized scene point. When another sensor is required, RAWForge
maps the point using the two fields of view, shows where it lands in that sensor's preview,
and asks that sensor to autofocus independently. An out-of-frame or unknown mapping is
shown for operator resolution rather than clamped. Manual lens position is chosen and
stored separately per sensor while viewing that sensor's preview; RAWForge never copies the
same actuator number to another sensor.

Focus intent normally clears after the Take. A clearly labelled **Keep focus for repeated
Takes** accelerator may retain the per-sensor intent while the Pose remains unchanged.
Manual lens position is presented as a sensor-relative control, never as a physical
distance. Every Frame records achieved lens position and the focus mode or availability
witness.

If a requested point or manual position is unsupported on a sensor, the interface requires
the operator to choose an available focus behavior; it never silently substitutes one.
Inability to hold an otherwise valid automatic focus is a visible warning and recorded
witness, not a capture block.

## 9. Recipe interface

### 9.1 Selected Recipe card

The collapsed card on Shoot shows:

- Recipe name and version;
- sensor order;
- total Frames;
- Burst/Sequential summary;
- exposure-series graphic;
- estimated duration and storage; and
- compatibility state.

Tapping the card opens Recipe details. A change button opens the library with compatible
Recipes first.

### 9.2 Ordered block editor

The editor is a vertical ordered list. Each collapsed Step shows sensor, series shape,
frame count, firing, exposure graphic, duration, and storage. Steps can be added,
duplicated, deleted, and reordered without a freeform canvas.

Opening a Step reveals the first disclosure level:

- sensor;
- Single, Repeat, or Exposure ladder;
- central shutter and ISO;
- count, rung spacing, or explicit values as applicable;
- Burst or Sequential.

One **Advanced** disclosure reveals:

- per-sensor EV offset;
- pre-capture dwell;
- Sequential-only inter-frame gap; and
- exact rendered and dropped rungs.

No expert parameter is deeper than this second level.

### 9.3 First launch

After camera permission, RAWForge selects a conservative compatible starter Recipe and
shows the live preview immediately. The Recipe card identifies it as a starter and explains
that it can be changed. There is no mandatory onboarding carousel, calibration, Plan, or
Run setup before the first capture.

Permission explanations appear immediately before the feature that needs them. Motion is
first exercised when the first Take begins, after a short inline explanation. If motion is
unavailable or denied, capture continues and the missing witness is recorded visibly.

## 10. Shoot states

| State | Primary control | Supporting behavior |
|---|---|---|
| Ready | Capture | Preview active; Recipe and estimates visible |
| Recipe blocked | Review Recipe | Exact incompatible Step and remedy visible |
| Low storage | Manage Storage | Estimated need and available space visible |
| Capturing | Stop after current burst | Current Step, Frame progress, elapsed and remaining estimates |
| Banking | Saving Take… | Capture disabled; progress retained |
| Completed | Capture Again | Result summary and Take link |
| Cancelled | Capture Again | No successful partial Take; cancellation explained |
| Failed | Try Again | Plain-language fault, recovery action, diagnostic identifier |
| Thermal warning | Capture | Expected slowdown shown; hard block only at unsafe state |

Status uses text and symbols as well as color. Dynamic Type does not hide the primary
action or compatibility message.

## 11. Library behavior

Recipes sort by recent use by default and support search by name, sensor, firing, and
series shape. Destructive actions require confirmation when the Recipe is the selected
Recipe, but deleting a library definition never removes past Takes.

Captures group by Run. A Run row shows date, name, Take count, frame count, storage, and
completion health. A Take row shows Recipe snapshot, pose label, sensors, duration, storage,
and witness summary. Export and delete operate at both Run and Take scope where record
integrity permits. A Take with unreadable metadata is listed as damaged rather than omitted.

Past records without a Recipe snapshot display as **Legacy capture** with their original
session/station/capture-set details. RAWForge does not guess a Recipe identity from matching
settings.

## 12. Compliance and support surface

### 12.1 Privacy policy and metadata

RAWForge ships a bundled privacy policy and links to a hosted copy from Privacy & Data.
App Store Connect uses the same hosted URL. For the planned public repository, the default
URL is `https://tangericm.github.io/RAWForge/privacy/`; publication must verify the URL
before submission. The GitHub repository homepage must stop pointing at the unrelated
PhotonForge project.

The audited product has no account, backend, analytics, ads, tracking, third-party SDK, or
Photos-library access. App Store privacy answers remain **Data Not Collected** while that
architecture remains true. A release checklist verifies the binary and dependency graph
before every submission rather than treating this answer as permanent.

### 12.2 Purpose strings

Use these release strings:

- Camera: “RAWForge uses the camera to preview your scene and save the RAW captures you
  choose to make.”
- Motion: “RAWForge records device motion during a capture so each RAW frame includes
  evidence of how steadily the phone was held.”

The app's inline pre-permission explanation uses the same benefit and states that capture
can continue without motion evidence.

### 12.3 Required-reason APIs

The privacy manifest declares:

- Disk Space with reason `E174.1`; and
- System Boot Time with reason `35F9.1`.

Before adding the System Boot Time declaration, persistence must stop storing or exporting
raw `systemUptime`. Monotonic time remains valid in memory, but durable records store only
elapsed values relative to app launch, Run start, Take start, or Frame sequence anchors.
Diagnostics likewise export relative durations, not the boot-time signal.

### 12.4 Privacy migration

The uptime correction is a versioned, idempotent migration:

1. discover known record formats by declared format and schema version;
2. decode a complete record before changing it;
3. derive relative values only when the record contains a trustworthy local anchor;
4. write a temporary replacement;
5. decode and validate the replacement;
6. atomically replace the metadata file; and
7. leave the original untouched and report a recoverable error on any failure.

DNG files are never rewritten. Unknown record versions remain untouched and visible as
requiring a newer RAWForge. Legacy plaintext logs containing raw uptime are removed because
their freeform contents cannot be normalized reliably; the user receives one explanation
that older diagnostic logs were cleared for privacy correctness.

### 12.5 Help & Settings contents

**Privacy & Data** explains on-device storage, Camera and Motion use, export, deletion,
backup behavior, the privacy policy, and the absence of accounts or analytics.

**This iPhone** shows detected sensors and rails, Burst ceiling, available storage,
measured-versus-borrowed timing values, Device profile freshness, and calibration status.

**Diagnostics** shows current health, recent fault identifiers, prior launch logs, build
identity, and Share Diagnostic Report. It does not expose developer instrument controls in
Release.

**Support** provides documentation, issue-report instructions, Copy Build ID, and the
public issue tracker once the repository is public.

**Open Source & About** shows version, build, commit, license, source link, iOS version, and
device identifier.

### 12.6 Submission artifacts

Version-controlled files under `docs/app-store/` contain:

- privacy-policy source;
- App Store privacy answers;
- permission-string source of truth;
- review notes and reproducible demo instructions;
- export-compliance answer;
- screenshot matrix;
- supported-device statement; and
- release checklist.

Secrets, certificates, provisioning profiles, and App Store credentials are never stored
in the repository.

## 13. Architecture boundaries

### 13.1 New domain and stores

- `Recipe`, `RecipeStep`, and `RecipeSnapshot` represent the visible workflow.
- `RecipeStore` owns versioned editable Recipes.
- `ActiveRunStore` owns only the resumable active-Run pointer.
- `SessionStore` remains the durable frame and record store.
- `ProtocolLibrary` remains a compatibility source for existing definitions.

Recipe rendering delegates to existing `CaptureSet`, `CaptureSpec`, rail validation, and
`ExecutionMode`. This avoids duplicating capture semantics.

### 13.2 Transaction ownership

`StationController` remains the owner of atomic Take transitions. It gains one high-level
operation equivalent to `captureTake(recipe:)`; low-level lifecycle methods remain internal
to the capture feature. `LiveStationCapture` remains the camera adapter. Views observe the
controller and issue intent, not transition sequences.

`CaptureModel` remains the composition root under
[ADR-0001](../../adr/0001-what-may-live-on-capturemodel.md). Recipe editing, active-Run
state, Help & Settings, and Library each bring their own observable model when they have
independent state. New capability does not accumulate as published properties on
`CaptureModel`.

### 13.3 Dependency direction

```text
Shoot view ─┐
Recipe UI ──┼─> workflow intents ─> StationController ─> camera/store/motion adapters
Library UI ─┘                            │
                                        └─> typed outcomes + immutable records

RecipeStore ─> Recipe ─> existing CaptureSet validation/rendering
ActiveRunStore ─> active Run identity ─> SessionStore
```

The UI does not construct file paths, mutate session records, or call AVFoundation.

## 14. Data flow

### 14.1 Planning

```text
Recipe draft
  -> render each Step for its physical sensor
  -> validate against Device profile
  -> report kept/dropped/blocked values
  -> estimate timeline and storage
  -> save a new immutable Recipe version
```

### 14.2 Capture

```text
Capture intent
  -> create/resume Run
  -> freeze Recipe snapshot
  -> open pending Take
  -> configure/focus/capture every Step
  -> bank Frames and witnesses
  -> atomically close Take
  -> return completed outcome

Any hard fault or safe-boundary stop
  -> abort pending Take
  -> remove orphaned Frames
  -> return failed or cancelled outcome with diagnostic ID
```

## 15. Record evolution

New schema versions add relative monotonic timing and an optional embedded Recipe snapshot.
Decoders continue accepting every format version already shipped. A field never changes
meaning while retaining the same name and schema version.

Past records without new fields remain browseable. Unknown fields are ignored only where
Swift decoding already permits it; unknown declared schema versions are not silently
treated as current. Migration is performed at an explicit boundary before capture, never
mid-write.

## 16. Error handling and diagnostics

Every user-visible failure includes:

- what did not complete;
- whether any successful data was retained;
- the safest immediate action;
- a stable diagnostic correlation identifier; and
- a route to share diagnostics.

Expected compatibility or storage problems are blocking validation, not runtime errors.
Transient camera failures allow retry after the controller has returned to a known phase.
Corrupt records remain listed by filename and do not prevent healthy records from loading.

The local flight recorder retains bounded structured events for app, workflow, camera,
store, motion, export, device probe, and UI. It never logs raw image data, raw boot time, or
private scene content. Diagnostic sharing remains explicitly user initiated.

## 17. Testing strategy

### 17.1 Unit tests

- Recipe versioning and immutable snapshots;
- Step rendering through existing CaptureSet generators;
- Burst/Sequential invariants and gap visibility;
- compatibility and explicit adaptation proposals;
- estimates and timeline composition;
- active-Run recovery;
- relative-time conversion and migration idempotence;
- old-record decoding; and
- user-facing outcome and error mapping.

### 17.2 Integration tests

Using in-memory camera, motion, clock, and store adapters:

- one action executes a one-Step and multi-Step Recipe;
- a repeat produces consecutive complete Takes in one Run;
- sensor swaps reacquire focus;
- stop waits for a safe boundary and leaves no successful partial Take;
- a fault in every phase removes orphaned Frames;
- relaunch resumes a valid Run and repairs an invalid pointer; and
- export contains relative timing and the frozen Recipe snapshot.

### 17.3 Interface tests

Add an XCUITest target with deterministic demo adapters. It verifies:

- first launch reaches a capture-ready starter;
- first capture and repeat capture;
- create, edit, reorder, and duplicate a multi-Step Recipe;
- Burst versus Sequential explanations and conditional gap control;
- incompatible Recipe recovery through Adapt a copy;
- Run/Take browsing, export, and deletion;
- Privacy & Data and diagnostic sharing; and
- Dynamic Type, VoiceOver labels/order, Increased Contrast, non-color status, and minimum
  touch targets.

The v1 product remains dark in accordance with the existing product decision. Release
screenshots and visual regression fixtures therefore cover dark appearance at standard and
large Dynamic Type rather than implying an unsupported light theme.

### 17.4 Release and hardware gates

CI builds and tests Debug and Release configurations, validates the privacy manifest,
scans the Release binary for development-only screens, builds an archive, and verifies the
stamped version/build/commit.

TestFlight verification covers the reference iPhone, at least one compatible single- or
two-sensor iPhone, and a newer Pro model. Hardware checks cover live preview, every physical
sensor, focus swap/return, long Burst splitting, Sequential read-back and gap, background/
foreground recovery, thermal warning, low storage, cancellation, export, and launch after
an interrupted write.

## 18. Delivery slices

1. **Privacy correctness:** relative-time model, record migration, privacy manifest,
   purpose strings, policy, metadata source, and tests.
2. **Recipe domain:** Recipe/Step/Snapshot models and adapters around CaptureSet.
3. **Run continuity:** active-Run pointer, recovery, Finish Run, and legacy presentation.
4. **One-action capture:** high-level controller operation, cancellation, typed outcomes,
   and deterministic integration coverage.
5. **Shoot shell:** two-tab navigation, live preview, starter, Recipe card, status, progress,
   and result surface.
6. **Recipe editing:** ordered blocks, two disclosure levels, versioning, adaptation, and
   import from existing definitions.
7. **Library:** unified Recipes and Captures browsing, detail, export, and deletion.
8. **Help & Settings:** compliance, device capabilities, diagnostics, support, and About.
9. **Interface verification:** deterministic XCUITest flows and accessibility pass.
10. **Release hardening:** archive automation, App Store artifacts, screenshots, TestFlight
    device matrix, and submission dry run.

Each slice must leave the repository buildable and records backward compatible. Temporary
bridges may exist between slices, but there is one capture engine and one source of truth
for exposure semantics throughout.

## 19. Acceptance criteria

1. A first-time user reaches a compatible live preview and starter Recipe without learning
   Plan, Protocol, Shot list, Set, Session, or Station.
2. One Capture action executes every Step and banks one complete Take.
3. Repeating the same Recipe takes one press and groups Takes in the active Run.
4. Burst and Sequential are visible on every Step and are never silently interchanged.
5. The gap control exists only for Sequential.
6. Exact exposure, focus, timing, storage, validation, and witnesses remain inspectable
   within two disclosure levels.
7. Missing sensors block capture and offer an explicit adapted Recipe copy. Unsupported
   custom focus requires an explicit Take-level choice; neither is silently substituted.
8. Cancellation and hard faults leave no successful partial Take or orphaned Frame.
9. Existing definitions and records remain readable and are never assigned guessed Recipe
   identities.
10. Privacy, permissions, deletion, export, device support, diagnostics, source, license,
    and build identity are reachable from Help & Settings.
11. Durable metadata and exported diagnostics contain no raw system uptime.
12. The App Store privacy manifest, Data Not Collected answers, privacy policy, purpose
    strings, and Release binary agree with the audited implementation.
13. Automated unit, integration, interface, accessibility, Release, and migration tests
    pass, followed by the defined TestFlight hardware matrix before public submission.
