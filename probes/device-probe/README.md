# Device probe harness — spike

A throwaway iOS app for the four spike items on
[#14](https://github.com/tangericm/RAWForge/issues/14) — the ones whose answers can invalidate a
closed decision or gate a destructive mechanism. **This is not the app.** No code here is expected to
survive; its output is numbers, facts, and a handful of DNGs pulled off the phone.

> **Untested on device.** Written before the Mac arrived, so it has never been compiled or run. The
> AVFoundation and CoreMotion usage is deliberately conservative, but treat the first build as a
> debugging session, not a clean run. Where an API behaves differently than assumed, that discrepancy
> is itself a probe result worth recording on #14.

## What it answers

| Item | Question | What the harness does | Verdict read from |
|---|---|---|---|
| **1** | Can a Bayer RAW *bracket* be captured at all? The bracket-settings docs imply `photoQualityPrioritization` can't be set on a bracket while Bayer forces `.speed`. | Opens the physical wide camera, requests a 3-frame manual-exposure bracket in a Bayer RAW format with ProRAW disabled, fires it. | Whether the capture succeeds and delivers 3 frames, on device. A success means the feared conflict does not block. |
| **3** | White-balance **pixel** path. Do locked Daylight gains reach the Bayer pixels, or only `AsShotNeutral`? | Captures the same scene under two very different locked WB gains (warm / cool), saves both DNGs, reports `AsShotNeutral` for each. | **Metadata limb** on device (does `AsShotNeutral` differ). **Pixel limb off device** — compare raw pixel values of the two DNGs on the Mac. |
| **14** | Is the Bayer path actually noise-reduction-free? `NoiseReductionApplied` reads 0/0 = *unknown*, not zero. | Dumps the full DNG + EXIF + TIFF dictionaries of a captured Bayer frame. | The `NoiseReductionApplied` value (and its absence, which is itself the answer: unknown, not zero). |
| **21** | What do a tripod and a handheld hold actually read? The stillness threshold now gates a **station abort**. | Records gyro magnitude and user-acceleration over a fixed window; reports percentiles. | Run three times — tripod-rigid, tripod-soft, handheld — and label each. Percentiles set the threshold. |

Two motion-axis items ride along because the same CoreMotion rig answers them:

| Item | Question | What the harness does |
|---|---|---|
| **19** | Does CoreMotion sampling survive a RAW capture session? | Measures effective sample rate and worst gap **with and without** a capture in flight. |
| **20** | Do CoreMotion and AVCapture share a timebase? | Captures a frame and reports `photo.timestamp`, the motion sample timestamp, and `systemUptime` side by side, so the offset (or lack of one) is visible. |

Everything else on #14 is a capability read the real app performs anyway, or a measurement that
refines rather than reshapes — not in this spike.

## Building it

No `.xcodeproj` is checked in — a hand-written project file is fragile across Xcode versions, and this
is throwaway. The project is generated from `project.yml` instead, so the spec is the source of truth
and the `.xcodeproj` stays out of git.

**Fast path (recommended) — one command:**

```
brew install xcodegen          # once
cd probes/device-probe
xcodegen generate              # writes DeviceProbe.xcodeproj + Info.plist
open DeviceProbe.xcodeproj
```

`project.yml` already sets the Info.plist keys (camera + motion usage, file sharing), the iOS 17
deployment target, iPhone-only, and **Swift 5 language mode** — the last because the motion sampler
captures across a queue on purpose, which Swift 6 strict concurrency would reject. Set your signing
team in Xcode (free personal team is enough; a 7-day profile is fine for a probe). This path is also
what lets **XcodeBuildMCP** build and test the probe headless on the Mac.

**Manual fallback** if you'd rather not install xcodegen: File ▸ New ▸ Project ▸ iOS App (SwiftUI),
delete the template `ContentView`/`App`, drag every `.swift` file in here, and add the four Info.plist
keys listed in `project.yml` by hand.

Either way: run destination is the **physical iPhone 15 Pro** — the camera probes do nothing in the
simulator.

## Reading the output

- The on-screen log is the live transcript. **Long-press it to copy**, and paste the run back onto #14.
- Saved DNGs land in the app's Documents directory. Pull them with Finder (device ▸ Files ▸ DeviceProbe)
  or a cable, and do the item-3 pixel comparison and any deeper DNG inspection on the Mac —
  `exiftool` and `rawpy` read what ImageIO won't surface on device.
- Item 21: run the stillness probe once per mounting condition and note which was which in the paste.

## Files

- `DeviceProbeApp.swift` — `@main`, one window.
- `ContentView.swift` — one button per probe, live log, copy.
- `ProbeLog.swift` — the observable transcript.
- `CaptureRig.swift` — opens the physical wide camera, configures Bayer RAW, wraps single and bracket capture.
- `BayerProbes.swift` — items 1, 3, 14.
- `MotionProbes.swift` — items 19, 20, 21.
- `DNGInspector.swift` — reads DNG / EXIF / TIFF metadata via ImageIO.
