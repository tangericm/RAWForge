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
   assertion as `PASS`.
- [ ] **4. Release binary scan:** `bash app/tools/release-check.sh` builds Debug and Release,
   validates its positive controls, and finds no developer-only code in Release.
- [ ] **5. Archive validation:** the archive is built from the release commit, passes Xcode
   Organizer validation, and its version, build, commit, privacy manifest, entitlements,
   and signing identity have been inspected.

## App Store material

- [ ] **6. Privacy-policy URL fetch:**
   `https://tangericm.github.io/RAWForge/privacy/` returns successfully over HTTPS, and the
   fetched bytes match `docs/app-store/privacy-policy.md`.
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

## Physical verification and approval

- [ ] **12. Hardware verification matrix:** TestFlight evidence covers the reference iPhone,
    a compatible single- or two-sensor iPhone, and a newer Pro model, including preview,
    every physical sensor, focus swap/return, long Burst splitting, Sequential read-back
    and gap, background/foreground recovery, thermal and low-storage handling,
    cancellation, export, and relaunch after an interrupted write.
- [ ] **13. Manual upload approval:** after reviewing every item above, a human release owner
    explicitly approves uploading this exact archive. No script performs the upload.

Approver: ____________________  Approval date/time: ____________________

Archive checksum: _____________________________________________________
