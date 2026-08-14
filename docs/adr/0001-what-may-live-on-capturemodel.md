# ADR-0001 — What may live on `CaptureModel`

**Status:** accepted · **Date:** 2026-08-14 · **Issue:** [#28](https://github.com/tangericm/RAWForge/issues/28)

## Context

`CaptureModel` had reached 1,015 lines across itself and its `StationFlow`
extension, with 29 `@Published` properties. A knowledge-graph pass put it at 76
edges — nearly double the next hub, `SensorCapability` at 38 — and checking
against the source confirmed that was not an artefact.

This had already cost something concrete. The station flow's phase transitions
could not be unit-tested for most of the project's life because they were
entangled with `CaptureRig` through this type. The eleven tests that now cover
them exist because the *decisions* were pulled out into `primaryAction`, not
because the object was untangled.

The pressure is ongoing rather than historical: #18 added three properties to it
in a single afternoon, and #21, #22 and #23 all add to it too.

The counter-argument, from the ticket itself, is the one that had to be tested
first: **a split that exists only to satisfy a graph metric buys nothing.** This
app has one screen doing one job at a time.

## Decision

Two parts, and the second is the load-bearing one.

### 1. The bench runs moved out

`runDarkCalibration`, `runWhiteBalanceProbe` and `runZoomProbe` are now
`BenchModel`. The seam was chosen by checking what those runs actually
reference, not by counting lines: they touch **no station-flow state at all** —
no `phase`, no `shotList`, no `pendingBrackets`, no `abortStation`. A dark
calibration is not a station. It opens its own session, its abort unit is the
setting rather than the run, and it never poses the phone at anything.

They *did* read session, capability, protocol and status straight off
`CaptureModel`. Moving the code while keeping those reads would have relocated
lines without removing coupling — exactly the split the ticket warned against —
so each run now takes an explicit request and returns an `Outcome` that the
caller applies. `BenchModel` never reads or writes `CaptureModel`.

### 2. The rule, which is what addresses the growth

**New capability does not become a property of `CaptureModel`.** A feature that
needs observable state brings its own `ObservableObject`, and the view observes
it directly.

`CaptureModel` keeps: the capability report, the session, the shot list, the
station flow and its pending records, the protocol library, and the operator's
settings. That is one job — *the state of the app between and during stations* —
and it is the job every screen depends on.

The honest limitation: **part 1 removed the least contested third and does
nothing about growth. Part 2 is what addresses growth, and a rule is only as
good as adherence to it.**

## What was deliberately not done

**`shoot()` stayed.** Extracting the 137-line capture executor was considered
and rejected on evidence. It looked like the move that would make it testable —
then checking showed it calls into `CaptureRig`, `SessionStore`, `DNGMetadata`
and `ClippingStats`, so testing it needs a faked rig behind a protocol. That is
a design change, not a move, and extraction alone buys tidiness only.

Its one cross-boundary use (the DEBUG white-balance probe) is injected as
`BenchModel.SetRunner`. That closure is not an accident: it is the named seam a
later ticket would cut along, kept visible rather than buried.

**The station did not move.** Pulling the flow, the pending records and the
focus plan into a `StationController` is the change that would actually address
growth structurally. It is also the riskiest change to the least-covered code —
no test exercises `shoot()` or any bench run, on device or off — and the phone
was disconnected. A bug introduced there would have surfaced on hardware tangled
up with #18's unverified focus work.

**Revisit this** if the rule is broken twice, or once #18 and #17 are verified on
hardware and there is coverage to refactor against.

## Consequences

- `CaptureModel.swift` 640 → 449 lines; `@Published` 29 → 26; the object and its
  extension together 1,015 → 824.
- `SetShot` moved to top level. A type that is the currency between the station
  flow and the bench runs should not live inside one of its two callers.
- Views observe `BenchModel` directly. Nested `ObservableObject`s do not
  republish through their owner, so `model.bench.darkProgress` would render once
  and then go stale mid-run.
- 145 tests pass unchanged. Nothing here is newly covered — the move is
  compiler-verified, which is the honest description of its safety.
