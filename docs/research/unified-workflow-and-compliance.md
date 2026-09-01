# A simpler RAWForge without making it less rigorous

Research and product recommendation · 2026-09-01

## Recommendation

RAWForge should feel like a camera when you use it and like a scientific instrument when
you inspect what it recorded.

That means keeping the rigorous session/station/capture-set model underneath, while no
longer asking the person holding the phone to operate that model manually. The visible
workflow becomes:

```text
Choose a Recipe → frame and focus → Capture → review or repeat
```

A **Recipe** is the complete reusable definition of what to capture. It contains one or
more ordered **Steps**. A **Take** is one all-or-nothing execution of the Recipe, and Takes
are grouped automatically into a **Run** for browsing and transfer.

Plan, Protocol, Shot list, Set, Session, and Station can remain stable implementation or
file-format concepts. They should not all remain things a user has to understand.

## Why the current workflow feels heavy

For a one-step starter capture, RAWForge currently asks for at least eight app actions after
camera permission: open Plan, choose a starter, add it, dismiss Plan, open a session,
declare a station, capture the set, and close the station. A multi-step capture adds another
button press for every set. Repeating the same capture still requires declare → capture each
set → close.

The problem is not a lack of polish. Internal transaction boundaries have become user
actions. The controller already knows the only valid next transition, so the extra presses
provide ceremony rather than meaningful control.

The vocabulary compounds this. A protocol defines exposures; a set combines that protocol
with a sensor; the shot list orders sets; Plan edits the shot list; a station executes it;
and a session groups stations. All of those distinctions are defensible in code. Most are
not helpful while someone is trying to take a picture.

## What strong tools do instead

Across camera and instrument software, the useful pattern is consistent:

- Put the live task and one obvious action first.
- Package many exact settings into a named, reusable, inspectable preset.
- Let advanced users open the preset and control every value.
- Keep metadata and diagnostics available without making them prerequisites.

[Blackmagic Camera](https://www.blackmagicdesign.com/products/blackmagiccamera) keeps
frequent controls on the camera display, stores complete configurations as presets, and
moves advanced monitoring/format controls to setup. [Lightroom Mobile](https://helpx.adobe.com/lightroom/mobile/add-and-capture-photos/capture-photos/capture-photos-in-pro-mode.html)
starts from an approachable camera and exposes exact shutter, ISO, white balance, and focus
in Pro mode. [Halide](https://www.lux.camera/halide-pro-camera-for-ipad/) uses dynamic,
ergonomic controls around the shutter and viewfinder. [Apple Shortcuts](https://support.apple.com/guide/shortcuts/apd84c576f8c/ios)
separates running a saved workflow from editing its ordered action blocks.
[Micro-Manager](https://micro-manager.org/Version_2.0_Users_Guide) shows the scientific
version of the same idea: low-level hardware properties become named presets and saved
acquisitions can run from one button.

This aligns with [Apple's onboarding guidance](https://developer.apple.com/design/human-interface-guidelines/onboarding),
which recommends useful defaults, immediate interaction, and contextual teaching, and with
[progressive-disclosure research](https://www.nngroup.com/articles/progressive-disclosure/):
show the few important choices first, reveal specialized options when requested, and avoid
nesting advanced detail more than two levels deep.

## The recommended product shape

### Two top-level areas

```text
┌──────────────────────────────┐
│ SHOOT                        │
│ [Run: Sep 1 field test  ›]   │
│                              │
│       LIVE PREVIEW           │
│      tap to set focus        │
│                              │
│ [Exposure ladder · 21f  ›]   │
│  1x + 3x · 8 s · ~210 MB     │
│                              │
│       [   CAPTURE   ]        │
│                              │
│ storage · thermal · motion   │
├──────────────────────────────┤
│       Shoot      Library     │
└──────────────────────────────┘
```

1. **Shoot** — preview, selected Recipe, active Run, focus, cost, Capture, progress, and
   immediate result/fault feedback.
2. **Library** — saved Recipes and captured Runs/Takes, with search, duplicate, export,
   and delete.

Console and Bench stop being peer tabs. A clearly labelled Help & Settings button from
both roots contains This iPhone, Privacy & Data, Diagnostics, Support, About, and open-
source information. Apple describes tabs as top-level sections and notes that fewer tabs
are generally easier to navigate ([Apple HIG: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)).

### One capture action

Tapping Capture should:

1. create or resume a Run;
2. open a Take;
3. execute every Step in the Recipe;
4. bank the complete Take, or delete it if any hard fault occurs;
5. return ready for the next Take.

The current progress and fault detail remain valuable. “Capture set 1,” “Capture set 2,”
and “Close station” stop being separate approvals. Safe cancellation remains available
during the run.

This reduces an unchanged multi-step repeat from `N + 2` presses to one without weakening
the atomic-record rule.

### A block-based Recipe, not a node editor

```text
Recipe: Reflectance ladder                     42 frames

  1  [ 1x ]  Exposure ladder  · 21 frames · Burst      ≡
     ▂▃▄▅▆▇█          4.2 s · ~210 MB                  ›

  2  [ 3x ]  Repeat           · 21 frames · Sequential ≡
     ━━━━━━━━━         9.8 s · ~210 MB                 ›

                     [+ Add step]

          Total 14 s · ~420 MB · 62% setup/waiting
```

Each collapsed Step shows sensor, shape, frames, Burst/Sequential firing, an exposure
graphic, time, and storage. Opening it reveals shutter, ISO, rungs, spacing, offsets, and
firing. A single Advanced disclosure reveals dwell and — only for Sequential — the gap.

A node canvas would be more flexible on paper and worse for the main task: it asks everyone
to program before shooting and spends scarce phone space on wiring. An ordered block list
keeps the useful part of Shortcuts while remaining a camera workflow.

### Automatic records, visible when useful

- **Run** is the folder-level group used for browsing and transfer. It starts on first
  capture, resumes after relaunch, and can be named or finished from the run chip.
- **Take** is a single atomic execution at one pose. Optional notes attach to the completed
  result instead of blocking capture.
- **Step** is one sensor-specific operation. All steps run under the same Capture press.

Existing session, station, and capture-set structures can stay on disk initially. This is
a user-language and orchestration change first, not a destructive format rewrite.

## How technical depth survives

Nothing is removed:

- exact shutter and ISO ladders;
- Burst versus Sequential semantics;
- sequential gap and dwell where they actually apply;
- per-sensor offsets and explicit sensor order;
- per-sensor automatic, point, or manual focus;
- time/storage breakdown and timeline;
- clipping, motion, focus, DNG, and device witnesses;
- saved/versioned definitions and immutable past records;
- device characterization and dark calibration;
- full logs and build identity.

The difference is where these appear. The primary screen answers “what will happen if I
press Capture?” The Step inspector answers “exactly how?” The record answers “what actually
happened?”

## Compliance surface

### What is already good

RAWForge has no account, backend, network stack, ads, analytics, tracking, Photos access,
or third-party SDK. Captures stay on device until the user exports them. Apple defines
“collected” data as data transmitted off device so the developer or a partner can access
it beyond servicing a real-time request; on-device-only processing is not collected
([Apple: App privacy details](https://developer.apple.com/app-store/app-privacy-details/)).
The audited app can accurately choose **Data Not Collected** in App Store Connect.

The app also already has a privacy manifest, user-controlled deletion/export, a Release-
only developer-tool boundary, export-compliance declaration, build stamping, and robust
local diagnostics.

### Release-blocking corrections

1. Add and host a privacy policy, then link it from the app and App Store Connect. Apple
   requires an easily accessible in-app link as well as the metadata URL
   ([Guideline 5.1.1(i)](https://developer.apple.com/app-store/review/guidelines/)).
2. Replace the purpose strings with plain user benefit:
   - Camera: “RAWForge uses the camera to preview your scene and save the RAW captures you
     choose to make.”
   - Motion: “RAWForge records device motion during a capture so each RAW frame includes
     evidence of how steadily the phone was held.”
3. Correct the privacy manifest. RAWForge calls `ProcessInfo.systemUptime`, which Apple
   lists as a System Boot Time required-reason API, but the manifest declares only Disk
   Space ([Apple: required-reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)).
4. Normalize stored/exported uptime to elapsed time from app launch, Run start, or Take
   start before declaring reason `35F9.1`. Apple allows elapsed durations to leave the
   device for that reason, but not the underlying boot-time signal. Current sessions and
   logs persist raw uptime, so adding a manifest entry alone would be incomplete.
5. Create one Help & Settings screen and a versioned submission checklist.

### Proposed Help & Settings

```text
Help & Settings
  Privacy & Data
    On-device data summary
    Camera and Motion permissions
    Storage, retention, export, and deletion
    Privacy Policy

  This iPhone
    Supported sensors and limits
    Measured vs borrowed timing profile
    Dark calibration and available storage

  Diagnostics
    Current device health
    Share diagnostic report
    Earlier logs
    Advanced instrument details

  Support
    Report an issue · Documentation · Copy build ID

  Open Source & About
    Source code · Apache-2.0 · Version/build/commit · iOS/device
```

This makes compliance useful: it answers what the phone can do, what RAWForge stores, how
to remove it, and how to provide evidence when something breaks.

## Alternatives considered

| Approach | Benefit | Why it is not the recommendation |
|---|---|---|
| Rename/reorganize only | Fast, low migration risk | The manual lifecycle remains; terminology improves but the work does not |
| Unified workspace + automatic records | One obvious capture path with full expert depth | Recommended; meaningful orchestration work, but fits the existing state machine |
| Node/canvas editor first | Maximum visible flexibility | Too much programming and navigation for routine capture on a phone |

## Delivery sequence

1. Fix uptime/privacy correctness, policy, links, purpose strings, and release metadata.
2. Add Recipe/Step and Run/Take presentation models around the existing durable records.
3. Make one Capture action execute and bank every Step atomically.
4. Replace the four-tab shell with Shoot + Library and contextual Help & Settings.
5. Build the graphical Recipe editor with one nested technical inspector.
6. Unify captures, recipes, device information, diagnostics, and support.
7. Run migration, workflow, accessibility, Release-archive, screenshot, TestFlight, and
   multi-device verification.

## Definition of success

- A first-time user can capture a starter without learning protocol, plan, session,
  station, or shot list.
- Repeating the same Recipe takes one press per Take.
- Every expert control is reachable within two disclosure levels.
- Every Take remains atomic and self-describing.
- Privacy, permissions, deletion, diagnostics, support, source, license, and build identity
  are reachable from one place.
- Dynamic Type, VoiceOver, sufficient contrast, non-color status cues, and large touch
  targets are verified using [Apple's accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility/).

## Evidence limit

This recommendation combines a direct code/task audit, current Apple requirements, and
first-party product documentation. It is not a substitute for usability testing. Before
public release, five or more novice/expert participants should attempt first capture,
repeat capture, and two-step Recipe authoring while we observe errors and questions. That
validation can be done without adding analytics or a backend.
