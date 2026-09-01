# ADR-0002 — User workflow is a facade over record boundaries

**Status:** accepted · **Date:** 2026-09-01

## Context

RAWForge exposes several defensible internal concepts as separate user tasks: a protocol
defines exposure values, a capture set binds those values to a sensor, a shot list orders
sets, a station executes that list atomically, and a session groups stations. A first
capture therefore requires operating the persistence model rather than simply describing
and taking a photograph.

The distinctions remain useful in code and in existing records. Renaming or flattening
their schemas would create migration risk without improving the capture itself. Leaving
them all visible, however, makes routine capture harder than the underlying state machine
requires.

## Decision

The product presents four primary concepts:

- a **Recipe** is the complete reusable capture definition;
- a **Step** is one sensor-specific operation in a Recipe;
- a **Take** is one atomic execution of a Recipe at one pose; and
- a **Run** is the durable group of Takes used for browsing and transfer.

These concepts form a user-workflow facade over the existing capture-set, station, and
session boundaries. One Capture action asks the station controller to execute every Step,
bank the complete Take, and leave the interface ready to repeat it. Views do not invoke
individual session or station transitions.

The Recipe editor is an ordered vertical block list with progressive disclosure. RAWForge
does not use a freeform node canvas for the primary workflow.

The canonical language is defined in [CONTEXT.md](../../CONTEXT.md).

## Consequences

- Existing records remain readable and retain their current format identifiers.
- A presentation model translates Recipe/Step into the existing capture structures.
- Past records may be labelled “Legacy capture” when they have no embedded Recipe
  snapshot; their meaning is not inferred or rewritten.
- Transaction ownership remains in `StationController`; the redesign does not create a
  second capture engine.
- Advanced controls and witnesses remain available within two disclosure levels, but the
  internal lifecycle is no longer a checklist for the operator.

## Alternatives rejected

**Rename the current screens only.** This lowers vocabulary cost but preserves the manual
session/station/set lifecycle and its unnecessary presses.

**Rename the durable schemas wholesale.** This makes implementation language match the
interface at the cost of a high-risk migration with no direct user benefit.

**Use a node-and-wire canvas.** It maximizes visible flexibility but turns a routine camera
operation into programming and performs poorly on a phone-sized screen. An ordered block
list preserves composition and exactness without the wiring overhead.
