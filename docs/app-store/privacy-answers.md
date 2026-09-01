# App Store Privacy Answers

Last architecture audit: 2026-09-01

## App Privacy

- Data collection: **Data Not Collected**
- Tracking: **No**

These answers are accurate for the audited RAWForge architecture: no account, backend, analytics, advertising, tracking, third-party SDK, Photos-library integration, or app-initiated network transmission exists. Camera frames, optional Motion evidence, capture metadata, and diagnostics are processed and stored on the iPhone. Data leaves the app only through an export or share action initiated by the user, and RAWForge does not receive that export.

The privacy manifest therefore declares an empty `NSPrivacyCollectedDataTypes` array, `NSPrivacyTracking = false`, and no tracking domains.

## Required-reason APIs

- Disk Space — `E174.1`: RAWForge reads available local capacity so it can refuse a capture that would exceed available storage instead of failing partway through.
- System Boot Time — `35F9.1`: RAWForge uses monotonic time in memory to calculate capture and diagnostic intervals. Durable records and exported diagnostics contain only segment-relative elapsed values, never raw system uptime.

## Permission strings

- Camera: “RAWForge uses the camera to preview your scene and save the RAW captures you choose to make.”
- Motion: “RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held.”

## Release condition

**Data Not Collected** and **Tracking: No** are release answers, not permanent assumptions. Before each App Store submission, audit the Release binary, dependency graph, entitlements, privacy manifest, and network behavior. If the architecture gains collection, tracking, a backend, an account, analytics, advertising, a third-party SDK, Photos access, or new network behavior, update these answers and the privacy policy before submission.
