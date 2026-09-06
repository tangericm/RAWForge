# Remaining overnight audit fixes

Follow-up to [the first safety fixes](2026-09-06-safety-fixes.md), on the same
`fix/audit-safety` branch. The original failing audit evidence remains on
`audit/overnight-20260906`.

## Resolved findings

- **A02 — interval estimates:** Sequential intervals are start-to-start floors.
  Estimate only the residual after the preceding rendered exposure and pipeline
  time, between frames only. This also corrects the legacy global interval path.
  A three-frame series with 1 s exposures and a 0.5 s floor adds no idle time.
- **A03 — migration conflicts:** An interrupted import compares the entire
  published recipe to its frozen journal before changing selection or clearing
  the old draft. A conflict is reported without overwriting either definition.
  Both sides are compared at their serialized date precision.
- **A05 — Stop during authored dwell:** Stop cancels the pre-Step timer and
  exits before camera preparation continues. It does not cancel an active
  hardware capture request. Ordinary waits and subsequent Takes are tested.
- **A06 — generated titles:** Generated starter titles follow mode/count changes
  through saving and reopening; stale titles saved by older builds are repaired
  when edited. Individually edited multi-frame sets use `Frames N` rather than
  claiming to remain a repeat or ladder. Independently authored custom names and
  positive-version library names are preserved.

## Evidence and limits

Before production changes, focused local tests reproduced incorrect interval
totals, the full two-second delay after Stop, conflicting migration source
deletion, and a saved Burst title on a Sequential step.

| Final branch verification | Result |
| --- | --- |
| Full unit suite | 336 tests, 15 hardware-only skips, 0 failures |
| Full simulator UI workflow suite | 6 tests, 0 failures |
| Optimized Release simulator build | Build succeeded |
| Repository privacy/compliance contract | 14 checks passed |
| Independent review | No outstanding in-scope findings |

Final local logs: `/tmp/rawforge-rest-verified-unit.log`,
`/tmp/rawforge-rest-verified-ui.log`, `/tmp/rawforge-rest-verified-release.log`.
Red evidence also includes `/tmp/rawforge-rest-red.log`,
`/tmp/rawforge-migration-red.log`, `/tmp/rawforge-titles-red.log`,
`/tmp/rawforge-a06-naming-red.log`, `/tmp/rawforge-a06-existing-red.log`, and
`/tmp/rawforge-a06-manual-red.log`. These are temporary local evidence, not
committed build artifacts.

Two exploratory UI checks were replaced by focused naming tests after text
entry appended digits instead of replacing the intended value. The retained
UI regression still verifies the real mode-change/save/reopen path. Additional
tests cover unchanged custom names, normal waits, subsequent Takes, and a
suspended camera response that must finish before Stop takes effect.

No physical phone/watch access was used. All six confirmed overnight findings
now have fixes and regression coverage across this change and `281561a`.
This does not replace camera-hardware validation or certify App Store readiness.
