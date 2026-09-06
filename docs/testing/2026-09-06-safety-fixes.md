# Overnight audit follow-up: timing and cleanup safety

Implemented on `fix/audit-safety`, based on `792bdd9`. Original failing evidence
remains on `audit/overnight-20260906`; this branch does not import that branch's
unrelated intentionally failing tests.

## A01 — unsupported timing values

- Recipe authoring, decoded-draft validation, legacy station execution, and the
  live sequential adapter share a checked seconds-to-nanoseconds conversion.
- Negative, non-finite, and out-of-range durations are rejected, not clamped to a
  different capture intent. The bound is the existing UInt64 nanosecond clock's
  representable range, not a new arbitrary product limit.
- The upper check is strict because `Double(UInt64.max)` rounds up to 2^64.
- Duration display is safe before validation: invalid values show `Unavailable`;
  extreme finite values use scientific notation. Large minute counts no longer
  truncate through a 32-bit format argument.
- Legacy invalid timing is refused before camera configuration. The live clock
  also logs and refuses unsupported inputs instead of trapping.

## A04 — mismatched Run ownership

- Cleanup requires a decodable current session header whose `sessionId` matches
  the folder. A mismatch preserves both DNG and motion files and emits a warning.
- Existing valid-header ownership rules are unchanged. The privacy cleanup
  journal's existing re-scan also uses the strengthened candidate discovery.
- This addresses a decodable foreign/empty identity, not arbitrary concurrent
  external replacement of files during deletion.

## Verification

Xcode 26.6, isolated iOS Simulator only. No phone or watch access and no deletion
of user captures. Filesystem regressions use private temporary fixtures.

| Check | Result |
| --- | --- |
| New validation/ownership regressions before fixes | 3 tests failed, 16 assertions, matching the audited mechanisms |
| Display and legacy-execution regressions before fixes | Failed, including the integer-conversion crash |
| Focused timing, ownership, controller, and storage suite | 46 tests, 0 failures |
| Full unit suite, including the additional conversion boundary test | 319 tests, 15 hardware-only skips, 0 failures |
| Repository privacy/compliance checks | 14 passed, 0 failed |
| Optimized Release build for generic iOS Simulator | Build succeeded |
| Independent read-only review of A01/A04 sources, callers, and tests | No actionable in-scope correctness findings |

Local run logs: `/tmp/rawforge-safety-red.log`,
`/tmp/rawforge-safety-display-red.log`, `/tmp/rawforge-safety-green.log`,
`/tmp/rawforge-safety-full.log`, and `/tmp/rawforge-safety-release.log`.
These temporary logs are evidence from this machine, not committed artifacts.

## Subsequent audit work

A02 sequential interval estimates, A03 interrupted recipe migration conflicts,
A05 stop responsiveness during dwell, and A06 stale generated titles were
subsequently addressed in [the remaining audit fixes](2026-09-06-audit-resolution.md).
These changes do not constitute hardware verification or App Store release approval.
