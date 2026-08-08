# iOS distribution: what each install path costs for a single-user instrument

Research for [RAWForge#4](https://github.com/tangericm/RAWForge/issues/4) · parent map [RAWForge#1](https://github.com/tangericm/RAWForge/issues/1)
Researched 2026-08-08. All primary claims are from `developer.apple.com`. Third-party sources are marked **[3P]** and are corroboration only.

**Use case this is judged against:** one developer, one iPhone 15 Pro, one instrument re-used across months of field capture sessions, no other users, no consumer purpose. Recurring friction is weighted far above up-front cost.

---

## Comparison table

| Path | Up-front cost | Recurring friction (re-sign / expiry cadence) | Toolchain requirement | Capability restrictions |
|---|---|---|---|---|
| **Free personal team** (Xcode Personal Team, no membership) | $0 | **7 days.** Provisioning profile expires 7 days from issuance; App IDs expire after 7 days; registered devices expire after 7 days. Re-provisioning means rebuild + reinstall from Xcode. ([compare-memberships]) | Mac + Xcode, physically present (cable or paired over local network) for **every** reinstall. Device must have Developer Mode on. ([running-your-app], [dev-mode]) | No TestFlight, no App Store, no App Store Connect upload (Validate/Export are disabled). "Advanced App Capabilities and Services" listed as ADP-only. Apple's own capabilities reference says free-account holders "can't distribute apps." ([compare-memberships], [QA1915], [caps-ios]) |
| **Paid ADP — development signing** | $99 / membership year | **~1 year**, bounded by cert + profile validity and by the membership year itself. Device list resets at the start of each membership year. ([programs], [devices]) *1-year profile figure not confirmed on a first-party page — see Unconfirmed figures.* | Mac + Xcode to build and install. Developer Mode required on device. ([registered-devices], [dev-mode]) | None that bite this app. |
| **Paid ADP — Ad Hoc / "Release Testing"** | $99 / membership year | **~1 year** (same bound). Explicitly avoids beta app review: registered-device distribution happens "without having to go through beta app review." ([registered-devices]) | Mac + Xcode to build and sign the `.ipa`. Installing it needs Xcode *or* Apple Configurator 2 *or* an OTA-hosted manifest — the profile itself lets the app "run on devices without needing Xcode." ([ad-hoc-profile], [registered-devices]) | 100 devices per product family per membership year — irrelevant at n=1. ([devices]) |
| **TestFlight — internal testers only** | $99 / membership year (ADP required) | **90 days per build.** "Your build becomes unavailable for testers after 90 days." Each new upload starts a fresh 90 days. ([testflight-overview], [add-internal]) | Mac + Xcode only to *produce* a build. **Install and reinstall need no Mac at all** — TestFlight app, invite email or redemption code. No Developer Mode needed: Developer Mode "doesn't affect ordinary installation techniques, such as buying apps from the App Store or participating in a TestFlight team." ([testflight-overview], [dev-mode]) | Uploads must be built with Xcode 26+ / iOS 26 SDK since 2026-04-28. Internal-only builds cannot later be submitted to the App Store. ([upcoming-reqs], [xcode-distribution]) |
| **App Store** | $99 / membership year + review | Per-submission App Review on every update. | Same as TestFlight, plus full App Store Connect metadata. | Guideline 4.2 Minimum Functionality. Apple explicitly routes this use case elsewhere (see Q4). ([review-guidelines]) |

---

## Q1 — Free personal team

**What Apple states, verbatim** ([compare-memberships]):

> **Xcode Personal Team.** If you're signing in to Xcode with an Apple Account that's not affiliated with the Apple Developer Program, you'll be able to perform on-device testing for personal use (Xcode refers to this as a Personal Team). However, there are some limitations to this type of development workflow that require you to re-provision the app to your device periodically, such as:
> * The number of App IDs that can be registered your account at one time is limited to 10 and each expires after 7 days.
> * The number of test devices that can be registered to your account for each platform is limited to 3 and each expires after 7 days.
> * Provisioning profiles will expire 7 days from issuance, which may require you to rebuild and re-install your app to your device after expiration.

- **Profile validity:** 7 days from issuance.
- **App expiry on device:** the app stops launching once its profile expires; Apple's wording is that you "rebuild and re-install." Apple does not describe the on-device failure mode on this page.
- **App-count limit:** Apple's current page states **10 App IDs** and **3 devices per platform**, not an app-install count. The widely repeated "only 3 apps installed at once" figure does **not** appear on Apple's current membership-comparison page — see Unconfirmed figures.
- **Cost of each reinstall:** a full Xcode build-and-run cycle against the physical device. There is no way to re-arm an existing install; the profile is baked into the installed app.
- **Must a Mac be physically present?** Yes, at least on the same local network. Xcode creates the development provisioning profile and registers the device as part of running on a physical device ([running-your-app]):
  > With the default "Automatically manage signing" option enabled under Signing on the Signing & Capabilities pane, Xcode registers the device and creates the development provisioning profile for you.
- **Extra device-side friction:** Developer Mode must be on. Toggling it requires a device restart and passcode confirmation, and it only appears in Settings after the device has been paired with a Mac ([dev-mode]):
  > Developer Mode only appears in Settings if you initiate pairing or if you previously paired the device to a Mac.
- **Hard ceilings:** no App Store Connect upload — "the Validate and Export buttons will be unavailable in the Xcode organizer" ([QA1915]); no TestFlight, no App Store distribution ([compare-memberships]).

**Verdict for this use case:** a 7-day expiry is disqualifying for field work. A multi-day trip out of reach of the build Mac ends with a dead instrument mid-session, and the failure lands exactly when it is most expensive — the capture cannot be redone.

---

## Q2 — Paid Apple Developer Program

**Fee.** "99 USD per membership year (or local currency equivalent)" ([compare-memberships], [whats-included]); the program landing page states "$99 annual membership" ([programs]). It is an auto-renewable annual subscription; fee waivers exist for nonprofits, accredited educational institutions and government entities — none of which apply here.

**What the $99 actually buys, for *this* app:**

1. **Access to Certificates, Identifiers & Profiles** — and with it, real distribution certificates and long-lived profiles instead of the 7-day personal-team ones.
2. **Device registration at scale.** "Members of the Apple Developer Program and Apple Developer Enterprise Program can register up to 100 of the following devices, per product family, per membership year" ([devices]). At n=1 this is irrelevant except for one detail: **the count only resets at the start of a new membership year**, and disabling a device does not free a slot:
   > You may disable a device on your list during the year, but doing so won't increase your number of available devices.
3. **Ad Hoc distribution.** Prerequisites are an App ID, a distribution certificate, and registered devices; the resulting profile lets you "run your app on devices without needing Xcode" ([ad-hoc-profile]). Apple's Xcode guide frames registered-device distribution as the pre-TestFlight channel ([registered-devices]):
   > Before Distributing your app for beta testing and releases, you can distribute progress builds to a limited set of users on known devices, without having to go through beta app review.
4. **TestFlight and App Store Connect.** "After you join the Apple Developer Program, Apple creates an App Store Connect account for you and you can start uploading builds." ([xcode-distribution])

**Ad Hoc install mechanics** ([registered-devices]) — the part that matters for an instrument:

> When you save the exported app, Xcode creates a folder that contains a few files, including the iOS App file, which is a file with an `.ipa` filename extension. Distribute that file to your users so they can install it on their devices by using Xcode or Apple Configurator 2.

and, for over-the-air, the Ad Hoc export offers an "Include manifest for over-the-air installation" option ([xcode-distribution]).

**What happens if you let the membership lapse** ([renewal]): you lose access to Certificates, Identifiers & Profiles; already-installed apps keep functioning; all registered devices are removed automatically 180 days after expiration. In practice the instrument keeps running only until its profile expires, and you cannot mint a new one without re-enrolling.

---

## Q3 — TestFlight

**Membership:** ADP only; TestFlight is marked unavailable to a free Apple Account ([compare-memberships]).

**Build expiry:** "Your build becomes unavailable for testers after 90 days" ([testflight-overview]); "Internal testers can download and test all builds for 90 days" ([add-internal]). Each new upload starts its own 90-day window.

**Internal vs external:**

| | Internal | External |
|---|---|---|
| Count | up to 100 App Store Connect users on your team ([testflight-overview]) | up to 10,000 ([testflight-overview]) |
| Eligible | Account Holder, Admin, App Manager, Developer, or Marketing role ([testflight-page], [add-internal]) | anyone by email or public link |
| Beta App Review | not required for internal-only builds | first build goes to App Review ([testflight-overview]) |
| Devices per tester | up to 30 ([testflight-page]) | up to 30 |

A solo developer enrolled as an individual **is** the Account Holder, so they qualify as an internal tester on their own app. Xcode has a first-class path for exactly this — a "TestFlight Internal Only" distribution option whose stated purpose is "to prevent a development build of your app from being submitted to the App Store," and such builds "can only be added to internal tester groups" ([xcode-distribution], [add-internal]).

**Turnaround:** internal-only builds skip Beta App Review; the delay is App Store Connect build processing, not human review. Apple does not publish a processing SLA.

**Can a solo developer use it as a private install channel?** Yes — this is the intended shape of it. The decisive property for field work is that **installation never touches a Mac**: testers install via the TestFlight app from an invite email or redemption code ([testflight-overview]), and Developer Mode is explicitly not involved ([dev-mode]):

> The feature doesn't affect ordinary installation techniques, such as buying apps from the App Store or participating in a TestFlight team.

**Constraint to plan around:** since 2026-04-28, "Apps uploaded to App Store Connect must be built with Xcode 26 or later using an SDK for iOS 26, iPadOS 26, tvOS 26, visionOS 26, or watchOS 26" ([upcoming-reqs]). This drags the toolchain floor for TestFlight above where Ad Hoc's floor sits.

---

## Q4 — App Store

Not a non-starter on the letter of the rules, but Apple itself tells you not to. From the App Review Guidelines "Get Started" section ([review-guidelines]):

> If you build an app that you just want to show to family and friends, the App Store isn't the best way to do that. Consider using Xcode to install your app on a device for free or use Ad Hoc distribution available to Apple Developer Program members.

And Guideline 4.2 Minimum Functionality:

> Your app should include features, content, and UI that elevate it beyond a repackaged website. If your app is not particularly useful, unique, or "app-like," it doesn't belong on the App Store. If your App doesn't provide some sort of lasting entertainment value or adequate utility, it may not be accepted.

RAWForge is an instrument with no consumer purpose and — per the map's out-of-scope list — deliberately no consumer product polish. That is precisely the profile 4.2 is written to filter. Even if it passed, the App Store buys nothing here: it adds a review cycle to every update in exchange for reaching an audience of one. The guidelines are a "living document" with no last-updated date, so 4.2's wording can shift without notice.

**Verdict:** rule it out — not because it would certainly be rejected, but because it is strictly dominated by TestFlight on every axis that matters at n=1.

---

## Q5 — Toolchain floor

**Every path requires a Mac to build.** There is no supported way to produce a signed iOS build without macOS + Xcode. The question is only how often the Mac must be *reachable*.

Current Xcode/macOS pairings ([xcode-reqs]):

| Xcode | Requires macOS | Device support |
|---|---|---|
| Xcode 27 beta 4 | macOS Tahoe 26.4 or later | iOS 17 or later |
| Xcode 26.6 | macOS Tahoe 26.2 – 26.x | iOS 15 or later |
| Xcode 26 | macOS Sequoia 15.6 – Tahoe 26.x | iOS 15 or later |

- **Floor for local install only (free or Ad Hoc):** any Xcode that supports the iPhone 15 Pro's installed iOS. Xcode 26 on macOS Sequoia 15.6 is sufficient; deployment targets reach back to iOS 15.
- **Floor for TestFlight / App Store:** **Xcode 26 or later with an iOS 26 SDK**, mandatory for App Store Connect uploads since 2026-04-28 ([upcoming-reqs]). Xcode 26 needs macOS Sequoia 15.6 at minimum; 26.5/26.6 need macOS Tahoe 26.2. Choosing TestFlight therefore couples you to a fairly recent macOS.
- **Build machine needed for reinstalls, or only for changes?**
  - *Free personal team:* **for reinstalls.** Every 7 days, no code change required.
  - *Ad Hoc:* **for changes only**, within the profile's life. The `.ipa` is a durable artifact; you can reinstall the same file via Apple Configurator 2 or an OTA manifest without rebuilding ([registered-devices]).
  - *TestFlight:* **for changes only**, and reinstalls need no Mac at all — but a build older than 90 days must be replaced by a fresh upload, which is a Mac-side action even if nothing in the code changed.

---

## Q6 — Capability gating

**Nothing in the map's locked constraints requires a paid membership.** Working through them ([RAWForge#1](https://github.com/tangericm/RAWForge/issues/1)):

| Locked constraint | API surface | Gate |
|---|---|---|
| Bayer RAW capture, 12 MP, three rear sensors | AVFoundation capture | Info.plist `NSCameraUsageDescription` — a privacy usage string, not a capability or entitlement ([nscamera]) |
| IMU capture (stretch) | Core Motion | Info.plist `NSMotionUsageDescription` — same ([nsmotion]) |
| Capture log / file output | app container, document sharing | Info.plist keys; no entitlement |
| Pinned WB, shutter bracketing, exposure range | AVFoundation device config | none |
| No ARKit, no cloud, no accounts, no IAP | — | the paid-only services (CloudKit, Push, Sign in with Apple, IAP, WeatherKit) are all in the map's out-of-scope list |

**The documentation is inconsistent here and it is worth knowing that.** Two Apple pages disagree:

- [compare-memberships] lists "Advanced App Capabilities and Services" as available to the Apple Developer Program only, and unavailable to a free Apple Account.
- [caps-ios] renders a three-column table (ADP / ADEP / Apple Developer) in which **every listed iOS capability is checked in all three columns**, including Push Notifications, iCloud, App Groups and Background Modes — while the same page defines the free "Apple Developer" tier as one where "developers can't distribute apps."

The operative constraint in practice is what Xcode surfaces: "The Capabilities library displays only the capabilities available to the target platform and your program membership" ([xcode-caps]), and Apple's Xcode docs state plainly that "whether you're a member of the Apple Developer Program... may limit the capabilities available to your app." Apple Developer Forums threads report Personal Teams being refused Push Notifications and App Groups **[3P — Apple-hosted but user-generated]**. Treat [caps-ios]'s all-checked table as unreliable.

**Why it doesn't matter here:** the capabilities RAWForge might plausibly want — Background Modes (if a long capture needs to survive backgrounding), Increased Debugging Memory Limit, Sustained Execution — are all listed as available to every tier, and none of the disputed paid-only services are in scope. **The $99 buys distribution ergonomics, not API surface.** If the app ever needed camera, motion and local file access alone, the free tier would be functionally complete and would still be unusable, purely because of the 7-day clock.

---

## Recommendation

**Pay the $99 and make internal-only TestFlight the install channel, keeping an Ad Hoc `.ipa` as the offline fallback** — the trade-off is $99/year plus a Mac-side re-upload every 90 days, bought in exchange for never needing a Mac in the field, versus $0 and a tethered rebuild every 7 days that will eventually strand a capture session.

Practical consequence for the rest of the design: **the recurring-friction budget is one build event per ≤90 days, and zero Mac dependency during a session.** Any design choice that would push reinstalls to a faster cadence — or that would require a laptop at the capture station — is spending against that budget and needs to justify itself.

---

## Unconfirmed figures — re-check before relying on these

1. **Development / Ad Hoc provisioning profile validity of "1 year" for paid members.** I could not find this stated on any first-party Apple documentation page. Apple's [profile-updates] page covers only offline profiles (7 days, with an extension request path for apps needing >30 days offline). The 1-year figure appears on Apple Developer Forums **[3P — user-generated]** and is the value shown in Certificates, Identifiers & Profiles in practice. **Verify by generating a profile and reading its expiry date** before treating "one year" as the field-work budget. If a shorter number turns up, the Ad Hoc fallback weakens and TestFlight becomes the sole recommendation.
2. **Whether an *already-installed* TestFlight build stops launching at 90 days, or merely stops being installable.** Apple's wording is "unavailable for testers after 90 days" ([testflight-overview]) and, on the manual-expire page, "The build no longer allows internal and external testers to install it" ([stop-testing]) — which describes installation, not launch. Forum reports of a "beta has expired" launch block are **[3P — user-generated]**. This is the single figure most load-bearing on the recommendation; confirm empirically on the first build.
3. **The "3 apps installed at once" personal-team limit.** Not present on Apple's current membership-comparison page, which states 10 App IDs and 3 devices instead. Circulated by third-party docs and blogs **[3P]**. Possibly superseded. Not load-bearing — the 7-day clock disqualifies the free path regardless.
4. **Beta App Review scope for internal groups.** [testflight-overview] says "When you add the first build of your app to a group, the build gets sent to App Review," without restricting that to external groups, while [add-internal] and [xcode-distribution] both describe internal-only builds as a channel that avoids submission. Assume internal-only skips review, but expect the first upload to be the moment you find out.
5. **The $99 fee and the 100-device limit** are current as of the pages fetched 2026-08-08, but both are the kind of figure Apple adjusts without announcement. The device limit is irrelevant at n=1; the fee is not.
6. **App Review Guidelines carry no last-updated date** and are explicitly a "living document" — 4.2's wording is a moving target.

---

## Sources

Primary — Apple official documentation and program pages:

- [compare-memberships] Choosing a Membership — https://developer.apple.com/support/compare-memberships/
- [programs] Apple Developer Program — https://developer.apple.com/programs/
- [whats-included] Membership Details — https://developer.apple.com/programs/whats-included/
- [devices] Devices overview — https://developer.apple.com/help/account/devices/devices-overview/
- [ad-hoc-profile] Create an ad hoc provisioning profile (iOS, tvOS, watchOS) — https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/
- [profile-updates] Provisioning profile updates — https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates/
- [renewal] Program Renewal — https://developer.apple.com/support/renewal/
- [registered-devices] Distributing your app to registered devices (Xcode) — https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices
- [xcode-distribution] Distributing your app for beta testing and releases (Xcode) — https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases
- [running-your-app] Running your app on simulated or physical devices (Xcode) — https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices
- [dev-mode] Enabling Developer Mode on a device (Xcode) — https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- [xcode-caps] Adding capabilities to your app (Xcode) — https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app
- [xcode-reqs] Xcode SDK and system requirements — https://developer.apple.com/xcode/system-requirements/
- [upcoming-reqs] Upcoming Requirements — https://developer.apple.com/news/upcoming-requirements/
- [testflight-page] TestFlight — https://developer.apple.com/testflight/
- [testflight-overview] TestFlight overview (App Store Connect Help) — https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- [add-internal] Add internal testers (App Store Connect Help) — https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- [stop-testing] Stop testing a build (App Store Connect Help) — https://developer.apple.com/help/app-store-connect/test-a-beta-version/stop-testing-a-build/
- [review-guidelines] App Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- [caps-ios] Supported capabilities (iOS) — https://developer.apple.com/help/account/reference/supported-capabilities-ios/
- [caps-overview] Capabilities Overview — https://developer.apple.com/help/account/capabilities/capabilities-overview/
- [certs] Certificates overview — https://developer.apple.com/support/certificates/
- [nscamera] NSCameraUsageDescription — https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription
- [nsmotion] NSMotionUsageDescription — https://developer.apple.com/documentation/bundleresources/information-property-list/nsmotionusagedescription
- [QA1915] Technical Q&A QA1915: Your (Personal Team) cannot be used to Code Sign your App for submission to the App Store (archived) — https://developer.apple.com/library/archive/qa/qa1915/_index.html

**[3P]** Corroboration only — Apple-hosted but user-generated, or non-Apple:

- Apple Developer Forums, personal-team 7-day expiry behaviour — https://developer.apple.com/forums/thread/51527 and https://developer.apple.com/forums/thread/69248
- Apple Developer Forums, Personal Teams refused Push Notifications / App Groups — https://developer.apple.com/forums/thread/84144 and https://developer.apple.com/forums/thread/718388
- Apple Developer Forums, TestFlight build 90-day expiry behaviour — https://developer.apple.com/forums/thread/720033 and https://developer.apple.com/forums/thread/702282
- Microsoft/Xamarin, Free provisioning (source of the "3 apps" figure) — https://learn.microsoft.com/previous-versions/xamarin/ios/get-started/installation/device-provisioning/free-provisioning
