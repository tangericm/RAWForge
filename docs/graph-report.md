# Graph Report - rf-graph  (2026-08-14)

## Corpus Check
- 64 files · ~76,587 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1109 nodes · 2270 edges · 61 communities (59 shown, 2 thin omitted)
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 199 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- SessionStore
- Codable
- CaptureSpec
- View
- ProbeController
- LogConsoleView
- DeviceCaptureTests
- Output contract: what does `photonforge` ingest actually read?
- CaptureRig
- DebugLog
- CapabilityReport
- CaptureModel
- Foundation
- CaptureRig
- DeviceHealth
- SessionEstimate
- .model
- EstimateCalibration
- logInfo
- DNG writing: AVFoundation's writer or a custom one, and does the metadata survive?
- SensorCapability
- .forShotList
- .captureBracket
- Rational
- ShotListStore
- ShotListEntry
- PlanSheet
- PrimaryAction
- StationPhase
- Category
- StationPlanView
- iOS distribution: what each install path costs for a single-user instrument
- PreviewUIView
- Viability gate: deterministic undemosaiced Bayer RAW from public iOS API
- RAWForge
- StationFault
- .entry
- ShotList
- ZoomProbeResult
- .report
- DeviceIdentity
- Sensor
- RigError
- Sub-question 4 — Exposure determinism
- UIKit
- ViewfinderPanel
- Agent skills
- Issue tracker: GitHub
- Sources
- Sub-question 2 — Suppressing ProRAW
- make-icon.py
- Domain Docs
- Sub-question 7 — Per-frame adaptation that cannot be disabled
- Sub-question 6 — Bracketing API
- Sub-question 1 — Bayer RAW availability per sensor
- Device probe harness — spike
- Advisory
- Sub-question 3 — Sensor selection determinism
- Sub-question 8 — Platform gating
- zip
- triage-labels.md

## God Nodes (most connected - your core abstractions)
1. `CaptureModel` - 76 edges
2. `SensorCapability` - 38 edges
3. `CaptureSpec` - 37 edges
4. `CaptureSet` - 36 edges
5. `DebugLog` - 33 edges
6. `CapabilityReport` - 32 edges
7. `SessionStore` - 30 edges
8. `ShotListEntry` - 27 edges
9. `CaptureRig` - 27 edges
10. `FrameRecord` - 23 edges

## Surprising Connections (you probably didn't know these)
- `.body` --calls--> `StationPlanView`  [INFERRED]
  app/RAWForge/UI/PlanSheet.swift → app/RAWForge/UI/StationPlanView.swift
- `.body` --calls--> `ContentView`  [INFERRED]
  probes/device-probe/DeviceProbeApp.swift → probes/device-probe/ContentView.swift
- `CaptureModel` --calls--> `ShotList`  [INFERRED]
  app/RAWForge/UI/CaptureModel.swift → app/RAWForge/Capture/CaptureFlow.swift
- `CaptureModel` --calls--> `DeviceHealth`  [INFERRED]
  app/RAWForge/UI/CaptureModel.swift → app/RAWForge/Capture/DeviceHealth.swift
- `CaptureModel` --calls--> `MotionRecorder`  [INFERRED]
  app/RAWForge/UI/CaptureModel.swift → app/RAWForge/Capture/MotionRecorder.swift

## Import Cycles
- None detected.

## Communities (61 total, 2 thin omitted)

### Community 0 - "SessionStore"
Cohesion: 0.06
Nodes (41): .fitsAvailableStorage, ExportError, coordinationFailed, .errorDescription, noSuchSession, SessionExport, Int64, String (+33 more)

### Community 1 - "Codable"
Cohesion: 0.07
Nodes (46): DroppedRung, Channel, .modeFraction, ClippingStats, .declaredWhiteLevelInBufferUnits, AVCapturePhoto, Double, Int (+38 more)

### Community 2 - "CaptureSpec"
Cohesion: 0.06
Nodes (43): CaptureSet, CaptureSpec, .id, .shutterLabel, ExecutionMode, hardwareBracket, .id, .label (+35 more)

### Community 3 - "View"
Cohesion: 0.05
Nodes (49): CalibrationView, .body, .plannedFrames, InstrumentChecksView, .body, RunSubject, .body, Int (+41 more)

### Community 4 - "ProbeController"
Cohesion: 0.08
Nodes (29): CMAcceleration, CMDeviceMotion, CMRotationRate, CMTime, BayerProbes, Bool, CaptureRig, Data (+21 more)

### Community 5 - "LogConsoleView"
Cohesion: 0.07
Nodes (30): App, RAWForgeApp, Scene, LogConsoleView, .body, .categories, .controls, .stream (+22 more)

### Community 6 - "DeviceCaptureTests"
Cohesion: 0.07
Nodes (17): .usableSensors, DNGMetadata, Any, CFString, Data, Double, Int, String (+9 more)

### Community 7 - "Output contract: what does `photonforge` ingest actually read?"
Cohesion: 0.05
Nodes (40): 10. Summary table — implemented vs planned, 1.1 Per-frame files, 1.2 Metadata that must be present in the DNG, 1.3 Directory layout, 1.4 Grouping, 1.5 Capture log / sidecar, 1. The output contract, as a checklist, 2. Sub-question 1 — File formats accepted (+32 more)

### Community 8 - "CaptureRig"
Cohesion: 0.09
Nodes (24): AVCapturePhotoCaptureDelegate, CustomStringConvertible, NSObject, CaptureRig, clamp(), fourCC(), PhotoCaptureCollector, RigError (+16 more)

### Community 9 - "DebugLog"
Cohesion: 0.10
Nodes (22): DebugLog, .directory, .generation, Entry, .clock, .line, Level, error (+14 more)

### Community 10 - "CapabilityReport"
Cohesion: 0.10
Nodes (26): CapabilityReport, .canCapture, .excludedSensors, .zoomAssertionViolations, Bool, Capability, .capabilities, .deepestBracketCeiling (+18 more)

### Community 11 - "CaptureModel"
Cohesion: 0.13
Nodes (17): CaptureModel, .bracketCeiling, .orderedSensors, SequenceFault, Shot, AVCapturePhoto, Date, Double (+9 more)

### Community 12 - "Foundation"
Cohesion: 0.17
Nodes (9): CapabilityProbe, AVFoundation, CoreMedia, CoreMotion, CoreVideo, Foundation, ImageIO, percentiles() (+1 more)

### Community 13 - "CaptureRig"
Cohesion: 0.14
Nodes (11): CaptureRig, .currentZoomFactor, .maxBracketCount, unsupported, AVCaptureDevice, Double, Float, Int (+3 more)

### Community 14 - "DeviceHealth"
Cohesion: 0.13
Nodes (15): DeviceHealth, .batteryFault, .batteryWarning, .summary, .thermalFault, .thermalLabel, .thermalWarning, AnyCancellable (+7 more)

### Community 15 - "SessionEstimate"
Cohesion: 0.14
Nodes (12): SessionEstimate, .typicalBytes, .typicalSeconds, .worstCaseBytes, .worstCaseSeconds, Bool, Int, Int64 (+4 more)

### Community 16 - ".model"
Cohesion: 0.24
Nodes (3): FlowStateTests, Bool, Int

### Community 17 - "EstimateCalibration"
Cohesion: 0.16
Nodes (10): EstimateCalibration, .isUseful, .summary, Bool, Double, Int, String, TimeInterval (+2 more)

### Community 18 - "logInfo"
Cohesion: 0.21
Nodes (9): logError(), logFailure(), logInfo(), logTrace(), logWarn(), Error, String, Bool (+1 more)

### Community 19 - "DNG writing: AVFoundation's writer or a custom one, and does the metadata survive?"
Cohesion: 0.12
Nodes (16): Custom-writer cost, DNG writing: AVFoundation's writer or a custom one, and does the metadata survive?, Frame identity — the load-bearing gap, Provenance and method — read this before trusting the measurements, Sources, Sub-question 1 — What does AVFoundation's writer actually emit?, Sub-question 2 — Tag survival, Sub-question 3 — Per-sensor identity (+8 more)

### Community 20 - "SensorCapability"
Cohesion: 0.15
Nodes (14): fourCC(), SensorCapability, .bayerFormatFourCC, .id, .isBayerCapable, .isUsable, .zoomAssertionHeld, Bool (+6 more)

### Community 21 - ".forShotList"
Cohesion: 0.27
Nodes (4): BracketSeamEstimateTests, SessionEstimateTests, Double, Int

### Community 22 - ".captureBracket"
Cohesion: 0.25
Nodes (9): PhotoCaptureCollector, AVCapturePhoto, AVCapturePhotoOutput, AVCapturePhotoSettings, AVCaptureResolvedPhotoSettings, Result, Void, BracketRun (+1 more)

### Community 23 - "Rational"
Cohesion: 0.19
Nodes (12): DNGRawTags, Rational, .description, .isUnknown, .value, Reading, Bool, Data (+4 more)

### Community 24 - "ShotListStore"
Cohesion: 0.21
Nodes (6): ShotListStore, .url, Stored, Bool, Date, URL

### Community 25 - "ShotListEntry"
Cohesion: 0.23
Nodes (8): .totalFrames, ShotListEntry, .frameCount, .id, .label, String, .shotListSection, IndexSet

### Community 26 - "PlanSheet"
Cohesion: 0.17
Nodes (11): .body, PlanSheet, .addControl, .estimate, .isEditable, .lockedNotice, .summarySection, Bool (+3 more)

### Community 27 - "PrimaryAction"
Cohesion: 0.15
Nodes (12): PrimaryAction, beginSet, blocked, closeStation, declareStation, .isEnabled, .isTerminal, openSession (+4 more)

### Community 28 - "StationPhase"
Cohesion: 0.17
Nodes (11): StationPhase, capturing, .isInStation, noSession, .note, sessionOpen, settling, stationOpen (+3 more)

### Community 29 - "Category"
Cohesion: 0.17
Nodes (11): Category, app, capture, export, flow, motion, probe, rig (+3 more)

### Community 30 - "StationPlanView"
Cohesion: 0.23
Nodes (7): StationPlanView, .estimate, .timeline, Bool, Color, String, TimeInterval

### Community 31 - "iOS distribution: what each install path costs for a single-user instrument"
Cohesion: 0.17
Nodes (11): Comparison table, iOS distribution: what each install path costs for a single-user instrument, Q1 — Free personal team, Q2 — Paid Apple Developer Program, Q3 — TestFlight, Q4 — App Store, Q5 — Toolchain floor, Q6 — Capability gating (+3 more)

### Community 32 - "PreviewUIView"
Cohesion: 0.24
Nodes (9): AnyClass, CameraPreview, PreviewUIView, .layerClass, .previewLayer, Context, AVCaptureVideoPreviewLayer, UIView (+1 more)

### Community 33 - "Viability gate: deterministic undemosaiced Bayer RAW from public iOS API"
Cohesion: 0.18
Nodes (10): Can gains be pinned to a fixed Daylight value?, Do the gains land in RAW metadata as written?, Open questions to settle on device before the dependent tickets, Per-sensor capability table, Recommended capture configuration, Source tiers, Sub-question 5 — White-balance determinism, Verdict (+2 more)

### Community 34 - "RAWForge"
Cohesion: 0.18
Nodes (10): History, How it behaves, License, Non-goals, RAWForge, Standalone by design, What the API allows, What the sensors actually do (+2 more)

### Community 35 - "StationFault"
Cohesion: 0.20
Nodes (8): StationFault, abandoned, batteryDeath, captureError, .operatorNote, storageExhausted, thermal, uncappedFrameInDarkRun

### Community 36 - ".entry"
Cohesion: 0.31
Nodes (3): ShotListTests, Int, String

### Community 37 - "ShotList"
Cohesion: 0.22
Nodes (7): ShotList, .canClose, .current, .remaining, Bool, Int, .settingsSection

### Community 38 - "ZoomProbeResult"
Cohesion: 0.31
Nodes (7): CaptureRig, Bool, Double, Int, String, Void, ZoomProbeResult

### Community 39 - ".report"
Cohesion: 0.47
Nodes (5): DNGInspector, Any, CFString, Data, String

### Community 40 - "DeviceIdentity"
Cohesion: 0.32
Nodes (4): DeviceIdentity, Bool, String, info

### Community 41 - "Sensor"
Cohesion: 0.25
Nodes (7): Sensor, .deviceType, telephoto, ultraWide, wide, AVCaptureDevice, CaseIterable

### Community 42 - "RigError"
Cohesion: 0.29
Nodes (7): RigError, captureFailed, .description, noBayerFormat, noDevice, notConfigured, String

### Community 43 - "Sub-question 4 — Exposure determinism"
Cohesion: 0.25
Nodes (8): Does `.custom` hold across a bracket?, Exposure bias — separate, and inert in `.custom`, Exposure metadata in the DNG, Local tone mapping — the residual adaptation, Range: full 1 s ceiling / 1/2000 s floor?, Sub-question 4 — Exposure determinism, The API, The single most important documented fact in this ticket

### Community 45 - "ViewfinderPanel"
Cohesion: 0.29
Nodes (7): .viewfinder, ViewfinderPanel, .badge, .body, .caveat, .corners, .idleState

### Community 46 - "Agent skills"
Cohesion: 0.29
Nodes (5): Agent skills, Domain docs, Issue tracker, Sibling repo, Triage labels

### Community 47 - "Issue tracker: GitHub"
Cohesion: 0.29
Nodes (6): Conventions, Issue tracker: GitHub, Pull requests as a triage surface, Wayfinding operations, When a skill says "fetch the relevant ticket", When a skill says "publish to the issue tracker"

### Community 48 - "Sources"
Cohesion: 0.29
Nodes (7): Apple developer documentation (P1), Apple, non-developer-documentation (P2), Apple SDK headers (P1 text, mirror transport), Apple WWDC sessions (P1), Corroboration only (C), Project-internal (measured, not Apple), Sources

### Community 49 - "Sub-question 2 — Suppressing ProRAW"
Cohesion: 0.29
Nodes (7): Can plain Bayer be requested unconditionally?, Does the system Settings ProRAW toggle affect a third-party app?, Enabling ProRAW is strictly additive — the key sentence, How the two are distinguished, Sub-question 2 — Suppressing ProRAW, What ProRAW actually does to the data — why it is disqualified, WWDC sessions

### Community 50 - "make-icon.py"
Cohesion: 0.40
Nodes (4): downsample(), quadrant_colour(), Box filter from N to SIZE — this is where the curves get their edges., render()

### Community 51 - "Domain Docs"
Cohesion: 0.33
Nodes (5): Before exploring, read these, Domain Docs, File structure, Flag ADR conflicts, Use the glossary's vocabulary

### Community 52 - "Sub-question 7 — Per-frame adaptation that cannot be disabled"
Cohesion: 0.33
Nodes (6): Deep Fusion, Smart HDR, semantic rendering, Lens shading, black level, per-frame gain — fully undocumented, Sub-question 7 — Per-frame adaptation that cannot be disabled, The complete list of RAW carve-outs Apple actually documents, The only documented ground truth for what was applied, Zero shutter lag, responsive capture, deferred delivery

### Community 53 - "Sub-question 6 — Bracketing API"
Cohesion: 0.33
Nodes (6): Documentation conflict — resolved, Documented bracket validation rules, RAW brackets are supported, with manual exposure, Sub-question 6 — Bracketing API, The bracket-count ceiling — the real open question, The fallback, if the ceiling is too low

### Community 54 - "Sub-question 1 — Bayer RAW availability per sensor"
Cohesion: 0.33
Nodes (6): Ordering, Per-sensor availability — what Apple actually documents, Related format APIs, Sub-question 1 — Bayer RAW availability per sensor, The Core Video Bayer constants, What `availableRawPhotoPixelFormatTypes` returns

### Community 55 - "Device probe harness — spike"
Cohesion: 0.33
Nodes (5): Building it, Device probe harness — spike, Files, Reading the output, What it answers

### Community 56 - "Advisory"
Cohesion: 0.40
Nodes (5): Advisory, elevated, handheldLike, .operatorNote, tripodLike

### Community 57 - "Sub-question 3 — Sensor selection determinism"
Cohesion: 0.40
Nodes (5): Can iOS still switch the active sensor mid-session on a single physical device?, Opening the physical devices directly — the documented path, Sub-question 3 — Sensor selection determinism, The switching-behavior API (iOS 15.0+) — present, but not needed here, The virtual device is not merely undesirable — it is unusable for this app

### Community 58 - "Sub-question 8 — Platform gating"
Cohesion: 0.50
Nodes (4): Entitlements: none, Minimum iOS version, Resolution gating, Sub-question 8 — Platform gating

### Community 59 - "zip"
Cohesion: 0.67
Nodes (3): A, zip(), B

## Knowledge Gaps
- **277 isolated node(s):** `.excludedSensors`, `.canCapture`, `.zoomAssertionViolations`, `.sharedBracketCeiling`, `.deepestBracketCeiling` (+272 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `CaptureModel` connect `CaptureModel` to `SessionStore`, `Codable`, `CaptureSpec`, `View`, `CapabilityReport`, `Foundation`, `DeviceHealth`, `.model`, `logInfo`, `SensorCapability`, `ShotListStore`, `ShotListEntry`, `PlanSheet`, `PrimaryAction`, `StationPhase`, `StationPlanView`, `StationFault`, `ShotList`, `ZoomProbeResult`, `ViewfinderPanel`?**
  _High betweenness centrality (0.201) - this node is a cross-community bridge._
- **Why does `SensorCapability` connect `SensorCapability` to `Codable`, `CaptureSpec`, `View`, `.entry`, `DeviceCaptureTests`, `Sensor`, `CapabilityReport`, `RigError`, `CaptureModel`, `CaptureRig`, `.model`, `.forShotList`, `ShotListEntry`?**
  _High betweenness centrality (0.083) - this node is a cross-community bridge._
- **Why does `Foundation` connect `Foundation` to `SessionStore`, `Codable`, `CaptureSpec`, `StationFault`, `ZoomProbeResult`, `CapabilityReport`, `UIKit`, `SessionEstimate`, `EstimateCalibration`, `logInfo`, `SensorCapability`, `Rational`, `ShotListStore`?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._
- **Are the 6 inferred relationships involving `CaptureModel` (e.g. with `.body` and `.body`) actually correct?**
  _`CaptureModel` has 6 INFERRED edges - model-reasoned connections that need verification._
- **Are the 18 inferred relationships involving `CaptureSpec` (e.g. with `.validated()` and `.presets()`) actually correct?**
  _`CaptureSpec` has 18 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `CaptureSet` (e.g. with `.beginNextSet()` and `.testEVOffsetRendersWithoutMutatingTheDefinition()`) actually correct?**
  _`CaptureSet` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `.excludedSensors`, `.canCapture`, `.zoomAssertionViolations` to the rest of the system?**
  _277 weakly-connected nodes found - possible documentation gaps or missing edges._