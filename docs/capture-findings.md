# RAWForge capture findings

Detailed sensor measurements and API notes, moved from the project README.
These findings describe the tested iPhone 15 Pro, not every iPhone.
For setup and everyday use, see the [README](../README.md).

Related references: [DNG validation and processing limits](research/dng-writing.md),
[Apple API sources](research/ios-raw-viability.md).

## What the sensors actually do

Measured on an iPhone 15 Pro, not assumed — the numbers that constrain the design:

| Property | Finding |
|---|---|
| Format | True Bayer RAW on all three rear sensors; 12 MP only, 48 MP structurally unavailable |
| Zoom | 2x is the main sensor cropped, not a fourth camera — it cannot be captured in RAW at all. Setting `videoZoomFactor != 1.0` **succeeds silently and then kills the process at capture**, with no catchable error, so the app enforces the invariant itself |
| Useful ISO ceiling | ~8-9x each sensor's base ISO. Base ISO measured on device: **1x 55 · 0.5x 32 · tele 18** (hardware ceilings 12320 / 3072 / 2304) |
| Consequence | Above that ceiling Apple applies pure digital gain — **bracket with shutter, not ISO** |
| Exposure range | 1 s ceiling. Floor **advertised** as ~1/66,000 s by `minExposureDuration` on all three sensors — the earlier 1/2000 s figure did not come from the device. RAWForge records requested, device, photo and DNG values rather than assuming the advertised rail is exact |
| CFA pattern | Not uniform across the phone — 1x is BGGR while 0.5x and tele are RGGB, confirmed in-file on frames RAWForge wrote |
| Active area | `ImageWidth` 4224 against an `ActiveArea` of 4032 — 192 padding columns to crop. `DefaultCropSize` agrees independently. Note ImageIO reports the *cropped* 4032 and hides the padding |
| Opcodes | `OpcodeList1` and `2` are **absent** — nothing is owed before demosaic and nothing has been applied to the payload. `FixVignetteRadial` sits in list 3 (post-demosaic), plus `WarpRectilinear2` on the ultra-wide only |
| Black level | Scalar 528 (`BlackLevelRepeatDim 1 1`), identical on all three sensors. `WhiteLevel` declares 4095, but the wide sensor's mass saturation was measured at raw 3567 (3039 above black), so clipping cannot be inferred from the declared tag alone |
| White balance | A locked WB reaches `AsShotNeutral` and **not the Bayer pixels** — measured at 1.00 where a pixel-level effect would have shown 9x. WB on this path is an annotation, not a transformation |
| Bracket depth | `maxBracketedCapturePhotoCount` is **8** on all three sensors. A longer Burst is automatically divided into requests of at most 8 frames, banking each request before the next; Sequential remains a separate, explicitly authored firing mode |
| Inter-frame gap | Within a hardware bracket: `max(33.4 ms, exposure)`. A split Burst pays a bank-and-release seam between requests. Sequential: 233-500 ms per frame, paid even when nothing changes between rungs |
| Sensor swap | ~370-400 ms to reconfigure between sensors — longer than an entire 8-frame bracket |
| `NoiseProfile` | A factor-of-2 sanity band, never a substitute for measured calibration |
| Pose | Must come from SfM downstream — ARKit and RAW capture are mutually exclusive |
| Motion | `CMDeviceMotion` is hard-capped at **100 Hz**, unaffected by capture in flight, and shares a timebase with `AVCapturePhoto.timestamp`. Handheld and tripod separate in the tail, not the median |

## What the API allows

Established from Apple's documentation, [issue #2](https://github.com/tangericm/RAWForge/issues/2):

- Deterministic Bayer capture is reachable from **public, un-entitled API**. `NSCameraUsageDescription`
  is the only requirement.
- Requesting Bayer RAW **forces** `photoQualityPrioritization = .speed` and `videoZoomFactor == 1.0` —
  and `.speed` is separately the precondition for `setExposureModeCustom` being honoured rather than
  overridden by fusion. Asking for Bayer is itself the request for determinism.
- Bayer RAW is offered only on **single-camera** `AVCaptureDevice`s. Virtual devices get ProRAW only,
  so sensor auto-switching cannot arise once a physical device is opened.
- Manual-exposure brackets have a documented RAW initializer — no sequential-capture workaround needed.
- Geometric distortion correction is never applied to RAW.

What Apple does **not** document has now largely been measured on-device in
[issue #14](https://github.com/tangericm/RAWForge/issues/14). The headline: a locked white balance
reaches `AsShotNeutral` and **not** the Bayer pixels, and is not re-metered at capture — so the
payload is the same data whatever the lock says.

Two of Apple's documented claims turned out to need qualification. `videoZoomFactor == 1.0` is not
*enforced* for Bayer: setting it away from 1.0 succeeds, and the violation terminates the process at
capture rather than returning an error. And `photoQualityPrioritization` does not in practice block a
manual-exposure Bayer bracket — an 8-frame bracket succeeds, which was the feared conflict.

