# RAWForge production program

The approved [unified workflow and compliance design](../specs/2026-09-01-unified-workflow-compliance-design.md)
is executed in this order:

1. [Privacy and compliance foundation](2026-09-01-privacy-compliance-foundation.md) —
   segment-relative timing, migration, manifest, policy, Help & Settings, and compliance CI.
2. [Recipe and Run orchestration](2026-09-01-recipe-run-orchestration.md) — versioned
   Recipes, active Run recovery, immutable snapshots, and one-action atomic Takes.
3. [Unified Shoot and Library interface](2026-09-01-unified-shoot-library-interface.md) —
   two-tab shell, camera-first Shoot, block Recipe editor, unified Library, and UI tests.
4. [Release hardening](2026-09-01-release-hardening.md) — archive validation, App Store
   metadata, deterministic screenshots, hardware matrix, TestFlight, and public release.

Each plan leaves the repository buildable and testable. Later plans depend on the named
interfaces from earlier plans; execution must not reorder them.
