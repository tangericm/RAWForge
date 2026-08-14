# Roadmap: from one phone to a project

Written 2026-08-14, after the app reached the point where it captures reliably
on one iPhone 15 Pro and is tested against real hardware.

This is a brainstorm with a recommended order, not a commitment. Mockups for the
UI proposals live on the `design/mockups` branch and are reachable with
`SIMCTL_CHILD_RAWFORGE_MOCKUP=1..4`.

---

## Where the app actually is

**Strong.** The measurement discipline is genuinely unusual: constants came from
runs rather than from documentation, rungs are dropped rather than clamped, the
four witnesses per frame make disagreement visible, and the session carries its
own protocol definition so a reader needs no registry. The flight recorder means
a field failure leaves evidence. The capability probe reflects rather than gates,
so the app already refuses honestly on hardware it cannot serve.

**The gap.** It is an instrument built by one person, for one person, on one
phone. Every barrier to a second user is either a hardcoded constant, a missing
contract, or a concept the operator has to already understand.

---

## 1. It works on *this* iPhone. That is the biggest lie in the app.

Seven constants in `SessionEstimate` are measured on an iPhone 15 Pro:

| Constant | Value | What it drives |
|---|---|---|
| `sensorFramePeriod` | 33.4 ms | in-bracket gap |
| `sequentialOverheadPerFrame` | 233 ms | sequential timing |
| `sensorSwap` | 400 ms | swap cost |
| `stillnessTimeout` | 0.4 s | the settle wait |
| `bracketSeam` | 567 ms | split-set timing |
| `averageFrameBytes` | 10.0 MB | storage plan |
| `worstCaseFrameBytes` | 30.7 MB | the fits/does-not-fit verdict |

On a 12 MP iPhone SE with one sensor, or a 48 MP iPhone 17 Pro, most of these are
wrong — and the failure is quiet. The plan still renders, still looks
authoritative, and is the thing the operator trusts when deciding whether to
hold a pose or whether a session will fit. **An estimate that is confidently
wrong is worse than no estimate**, which is this project's own standard applied
to itself.

The good news is that the app already knows how to measure all seven; that is
where the numbers came from. The work is turning a thing that happened once on
a desk into a feature.

**Proposal — device characterisation (mockup 3).** A ~40 s, 24-frame run,
scene-independent, that measures the seven and writes a device profile. The
profile is stamped into every session header, so a file says which profile it
was planned against. Until it runs, estimates are labelled *borrowed* rather
than presented as fact.

Second half: a **community profile set** shipped with the app, keyed by
`modelIdentifier`, so a new device has decent priors before it measures. Opt-in
contribution, hardware numbers only — never frames, never locations.

This is the single highest-value change for a broad user base, and it is
directly in the project's grain: measure, don't assume.

### What else portability needs

- **Never gate on model.** Already the rule (#6). Keep auditing for it.
- **Single-sensor devices.** The shot list, swap accounting and per-sensor EV
  offsets all assume several rear cameras. On an SE these should collapse, not
  render as a menu of one. Partly done in the plan sheet; needs a sweep.
- **Bracket ceilings other than 8.** Now handled by splitting, but untested
  against a device reporting a different ceiling — the split arithmetic is
  covered by unit tests, the hardware path only at 8.
- **CI.** The simulator suite (48 tests) can run on every push today. The
  hardware suite (18) cannot without a device runner; a documented
  "run before release" checklist is the honest interim.

---

## 2. Make the session format a public contract — `pip install rawforge`

Right now the session layout is an implementation detail that `photonforge`
happens to know. That is the main thing stopping anyone else using what this
app produces, and it costs nothing to fix beyond discipline.

**Proposal, in three parts:**

1. **A versioned JSON Schema** for the session, station and frame records, in
   this repo, with a stated compatibility policy. `schemaVersion` already
   exists; the schema makes it mean something.
2. **A reference reader on PyPI.** Not a port of the app — a *reader*:

   ```python
   import rawforge

   session = rawforge.open("20260813T193040Z")
   for station in session.stations:
       for frame in station.frames:
           frame.requested.shutter      # what the protocol demanded
           frame.dng.exposure_time      # what the file claims
           frame.clipping.green.p99     # measured, on device
           arr = frame.raw()            # rawpy, lazily
   ```

   The value is not convenience, it is that **the four witnesses stay joined to
   the pixels**. Anyone doing photometry gets the disagreement for free rather
   than reconstructing it from EXIF.

3. **A CLI** — `rawforge validate` (does this session match the schema),
   `rawforge summary`, `rawforge export --csv`. Validation matters most: it lets
   a contributor prove a capture is well-formed without owning the app.

Also worth publishing: the **measured findings** as a small dataset. The #14
answers, the seam measurement, the stillness decay study. That is the part of
this project that is genuinely novel and currently lives in issue comments.

---

## 3. Simplify: what to cut, what to hide, what to make graphical

### Real bloat, safe to remove

- **Execution mode as a decision.** With splitting implemented, "bracket vs
  sequential" is almost always answerable by the app: bracket if it fits or can
  be split; sequential when the protocol needs a per-rung device
  reconfiguration. Make it automatic with an override in Advanced, not a
  question asked up front.
- **Group-by-sensor toggle.** Inferable. Grouping is right unless an order was
  authored, which the app already detects.
- **Min inter-frame gap and extra dwell.** Expert knobs, near-zero use. Advanced.
- **The instrument checks** (white-balance pixel path, zoom enforcement).
  These answered specific research questions and the answers are now known.
  They are developer tools; put them behind a Developer toggle.

That removes roughly half the controls a new user meets without losing anything
a power user can't reach.

### Make the plan graphical (mockup 1)

Today the shot list is a list and the timeline is a screen behind it. They are
the same fact — *what* you shoot and *when* it happens — split in two.

The proposal draws the station as a schedule to scale: swap, settle, set, seam,
each block sized by its duration, with the ladder's rungs drawn from its own
exposures. Two things fall out of it that prose cannot deliver:

- The costs you did not add — swap, settle, seam — are visibly the expensive
  ones. A three-sensor station is mostly *not* shooting, and that should be
  obvious before the pose is held rather than surprising during it.
- A badly-centred sweep looks wrong on screen, before it is shot.

This is the "blocks-based" idea, but the blocks are a **timeline** rather than a
node graph. A node editor would add a second thing to learn; a timeline is the
thing the operator is already holding a pose against.

### Give newcomers a way in (mockup 2)

A fresh install today is a wall: no protocols exist → no shot list → no station
→ nothing can be shot until something has been authored. Correct for the
instrument, fatal for adoption.

**Quick mode**: three intents — Bracket, Burst, Single — that expand into real,
named, versioned protocols the moment they fire. Nothing about the record gets
weaker; the provenance requirement is met by generating a genuine protocol
rather than by skipping one. Protocol mode is exactly today's screen.

### Answer the question every operator has (mockup 4)

The app already computes a full 16-bit histogram per CFA channel over the active
area of every frame, and shows it as six-decimal numbers. As bars, it answers
"did I clip, and where" in about a second — at the pose, while the light is
still there, rather than on a workstation afterwards.

Nothing here crosses #12: this is the Bayer payload, not the preview.

---

## 4. Features that would broaden the audience

Roughly in order of value-to-effort:

- **Focus control.** *The most serious functional gap.* Focus is as important as
  exposure for repeatability and the app does not touch it — a locked focus
  distance belongs in the protocol. Without it, "deterministic capture" is
  overstated.
- **Volume-button and headphone-remote trigger.** The single largest motion
  event measured in this project is the button tap. A remote trigger removes it
  outright, and it is a few lines.
- **Protocol import/export.** Already JSON on disk with file sharing on. Sharing
  a protocol as a file is nearly free and makes methods reproducible between
  people, which is the point of the whole app.
- **Focus stacking** — macro/product photography is a large, underserved
  audience whose needs this architecture already fits.
- **Interval capture** — repeat a station every N seconds, for time-lapse
  photometry.
- **ISO as a sweep axis.** It is a legitimate axis with a warning already
  written; the generator is shutter-only.
- **Apple Watch trigger** — same motivation as the remote, more work.
- **Session notes** per station, including voice.

Deliberately *not* proposed: any live statistic from the viewfinder, any
demosaic, any cloud sync. The first two are the line #12 draws; the third is
against #11's whole transfer model.

---

## 5. Deployment: what has to be in place

### Blocking — nothing ships without these

**Apple Developer Program, $99/yr.** The app is currently signed with a personal
team, which means 7-day provisioning and no TestFlight at all. This is the hard
gate; everything else below assumes it.

**`PrivacyInfo.xcprivacy`.** Absent, and its absence is an *upload* rejection,
not a review note. Audited against the actual code, one required-reason category
applies:

| API | Where | Category | Reason |
|---|---|---|---|
| `volumeAvailableCapacityKey` | `SessionStore.availableCapacityBytes` | `DiskSpace` | `E174` — checking there is room before writing |

Checked and *not* needed: no `UserDefaults` anywhere (the shot list and
protocols are files, so `CA92.1` does not apply); `.fileSizeKey` is not a
file-timestamp API; no ad identifiers, no active keyboard, no system boot time.
Declaring only what is used matters — an over-broad manifest invites questions.

**Export compliance.** No encryption beyond what the OS provides, so set
`ITSAppUsesNonExemptEncryption = false` in Info.plist. Without it every single
submission stops to ask.

**Build numbers that increment.** Every build reports `1.0 (1)`, so two logs
from different builds are indistinguishable — already a problem in testing, and
App Store Connect rejects a duplicate build number outright. Stamp from git at
build time.

**Privacy policy URL and support URL.** Both required fields on the App Store
listing even though the app collects nothing. A page in this repo is enough.

### CI/CD

The split is forced by hardware: 48 of the 66 tests run on a simulator and
belong in CI; 18 need a real sensor and cannot run on a hosted runner.

- **On every push** (GitHub Actions, `macos-latest`): `xcodegen generate`, build
  Debug **and Release**, run the simulator suite. Release matters — it had never
  been built until today, and whole-module optimisation is exactly where a
  latent problem would surface.
- **Hardware suite**: tagged and skipped in CI, run from a Mac before any
  release. A checklist is the honest interim; a self-hosted runner with a
  tethered phone is the real answer if this gets serious.
- **Release upload**: `xcodebuild -exportArchive` plus an App Store Connect API
  key in secrets. Fastlane is optional at this size.
- **Watch the macOS minute multiplier** — GitHub bills macOS at 10×. Keep the
  matrix small.

### Verified today

- Release configuration builds clean.
- `#if DEBUG` correctly excludes the mockups and the tab/mockup launch
  overrides from the Release binary — confirmed by inspecting its strings.
  (Worth re-checking whenever debug-only code is added, since this project had
  `#if DEBUG` compiling to nothing until recently.)

### Review-process notes

- **Camera usage string.** Reviewers read it. "RAWForge captures Bayer RAW
  frames to a protocol" is accurate but jargon; say what the user gets.
- **Reviewer notes.** Explain that captures land in Files and that there is no
  photo-library integration, or a reviewer will look for the pictures and not
  find them. Include a one-line walkthrough: open session → add a set → declare
  → capture → close.
- **Guideline 2.1, completeness.** The bench's developer-only probes should be
  behind a Developer toggle before submission; they read as unfinished
  scaffolding.
- **Guideline 4.2, minimum functionality.** A niche professional tool is fine,
  but Quick mode (mockup 2) materially helps here — a reviewer who cannot shoot
  anything in 30 seconds is a risk.
- **Screenshots** at 6.9" and 6.5". A capture app with no photo library needs
  its screenshots to carry the story.

### Performance to check before shipping

- **`ClippingStats`** does ~12.2 M iterations per frame. Never profiled in a
  Release build; it may be entirely fine with optimisation on, but it sits in
  the capture path and a 48 MP device will be worse than this one.
- **Peak memory** during a split bracket, on a 48 MP device — eight buffers plus
  a write plus a histogram.
- **Thermal behaviour** over a long session, which the self-calibrating estimate
  handles but which has never been deliberately provoked.

### Project hygiene

- **LICENSE and CONTRIBUTING.** It is an open-source project with neither.
- **Crash reporting** consistent with the no-telemetry stance: the unclean-exit
  marker and the log file already exist, so a "share this crash" affordance is
  enough and needs no server.
- **TestFlight before the store**, which is also the only realistic answer to
  the device-matrix problem — other people's phones are the test lab.

---

## Suggested order

**Phase 1 — honest on any iPhone.** Device characterisation, borrowed-value
labelling, single-sensor sweep, focus control, build stamping, privacy manifest.
*Rationale: everything else is built on estimates being true.*

**Phase 2 — the contract.** Session JSON Schema, `rawforge` on PyPI, CLI,
published findings. *Rationale: this is what makes it a project rather than an
app, and it is independent of UI work.*

**Phase 3 — the interface.** Timeline plan, Quick mode, clipping review,
advanced-disclosure sweep. *Rationale: worth doing after Phase 1 so the timeline
draws real numbers.*

**Phase 4 — reach.** Remote triggers, protocol sharing, focus stacking,
TestFlight, store.

The one I would not defer is **focus control**. It is a correctness gap in the
core claim, not a feature.
