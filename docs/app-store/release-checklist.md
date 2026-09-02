# RAWForge Release Checklist

Complete this checklist for the exact commit and archive proposed for upload. Attach or
link evidence beside each item; a result from another commit or archive does not count.

Release commit: ____________________  Version/build: ____________________

Archive path or identifier: ____________________________________________

## Software candidate

- [ ] **1. Clean tree:** `git status --porcelain` is empty, and the release commit above is
   the checked-out `HEAD`.
- [ ] **2. Simulator suite:** project generation succeeds and the complete iPhone 17 Pro
   simulator suite reports zero failures.
- [ ] **3. Compliance checker:** `bash app/tools/check-compliance.sh` reports every labelled
   assertion as `PASS`, including byte identity among the three local privacy-policy
   sources.
- [ ] **4. Release binary scan:** `bash app/tools/release-check.sh` builds Debug and Release,
   validates its positive controls, and finds no developer-only code in Release.
- [ ] **5. Archive validation:** the archive is built from the release commit, passes Xcode
   Organizer validation, and its version, build, commit, privacy manifest, entitlements,
   and signing identity have been inspected.

## App Store material

- [ ] **6. Hosted privacy-policy verification:**
   `https://tangericm.github.io/RAWForge/privacy/` follows redirects to an HTTP 200 response.
   The normalized rendered page—not its HTML bytes—shows the title **RAWForge Privacy
   Policy**, effective date **2026-09-01**, and the sections **Permissions**, **Data stored on
   this iPhone**, **Export and transmission**, **Deletion and retention**, **iCloud backup**,
   **Diagnostics**, **Analytics and tracking**, and **Contact**.
- [ ] **7. App Store privacy answers:** App Store Connect says **Data Not Collected** and
   **Tracking: No**, matching `docs/app-store/privacy-answers.md` and the audited Release
   binary, dependency graph, entitlements, manifest, and network behavior.
- [ ] **8. Purpose strings:** the archived app contains the approved Camera and Motion
   descriptions from `app/project.yml`, with no stale or alternate wording in App Store
   metadata.
- [ ] **9. Export compliance:** App Store Connect and the archived Info.plist both record
   `ITSAppUsesNonExemptEncryption = false`, matching
   `docs/app-store/export-compliance.md`.
- [ ] **10. Screenshots:** every required device size and scenario is present, current,
    legible in dark appearance, free of private data and error overlays, and checked at
    standard and large Dynamic Type.
- [ ] **11. Review notes:** App Review notes and demo steps match this build, identify the
    compatible physical-iPhone requirement, and need no account, network, or accessory.

## TestFlight and physical verification

- [ ] **12. TestFlight upload approval:** after reviewing items 1–11, a human release owner
    approves manually uploading this exact archive to TestFlight. No script performs the
    upload.

TestFlight approver: ____________________  Approval date/time: ____________________

TestFlight build number: _______________  Archive checksum: ______________________

- [ ] **13. Hardware verification matrix:** the approved TestFlight build above is installed
    from TestFlight and its evidence covers the reference iPhone,
    a compatible single- or two-sensor iPhone, and a newer Pro model, including preview,
    every physical sensor, focus swap/return, long Burst splitting, Sequential read-back
    and gap, background/foreground recovery, thermal and low-storage handling,
    cancellation, export, and relaunch after an interrupted write.
- [ ] **14. Final App Store submission approval:** after reviewing every item above,
    including the completed TestFlight hardware matrix, a human release owner explicitly
    approves submitting this exact build to App Review. No script performs the submission.

App Store approver: ____________________  Approval date/time: ____________________

Approved build number: ________________  Archive checksum: ______________________
