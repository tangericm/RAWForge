# RAWForge

**An iPhone capture app for photometrically deterministic RAW — bracketed, undemosaiced Bayer
frames with metadata you can calibrate against, shot to a protocol instead of by hand.**

> **Status: building.** The design spec is settled — thirteen decisions closed on the project map
> ([`wayfinder:map`](https://github.com/tangericm/RAWForge/issues?q=label%3Awayfinder%3Amap)) — and
> the app now captures multi-sensor Bayer stations to disk with a capture log, an IMU stream and a
> four-witness exposure record. The numbers in the table below are measured **by this app, on frames
> it wrote**, not inherited from a third-party capture. What remains open is tracked on
> [#14](https://github.com/tangericm/RAWForge/issues/14).

---

## What this is

An instrument, not a camera app. It captures true Bayer RAW under parameters that are fixed,
measured or recorded — never inferred afterwards — so the frames can be calibrated against rather
than merely looked at.

The bar it is designed to: **a reader holding only the frames and the capture log, with no access
to the photographer, can tell exactly what was shot and under what protocol.**

Consumer camera apps do not state, and cannot be assumed to hold, the properties that requires:

- **True Bayer RAW, undemosaiced.** ProRAW is disqualified — it ships `NoiseReductionApplied = 0.95`,
  so the "clean" frame is already denoised and calibrating a noise model against it is circular.
  The Bayer path is *not* the mirror image of that claim: it ships `NoiseReductionApplied = 0/0`,
  which the DNG spec defines as **unknown, not zero**. Bayer being noise-reduction-free is
  uncontradicted by the file, never asserted by it.
- **Deterministic capture parameters.** Fixed white balance, known ISO and shutter, no per-frame
  adaptation, no zoom-dependent sensor switching.
- **Brackets that share a pose.** Exposure stacks from a fixed station, grouped explicitly rather
  than left to filename convention.
- **Metadata that survives.** Black level, active area, CFA pattern and per-sensor identity carried
  through to the file, because the three iPhone sensors need three separate calibrations.

Off-the-shelf manual apps clear the format bar — Halide's Process Zero emits genuine undemosaiced
Bayer on all three rear sensors — but the protocol still lives in the photographer's head, and the
capture path is closed to anything the app's author did not anticipate.

## Why build it

Two things a third-party app cannot give:

1. **Protocol as code.** Capture sets — ordered lists of `(shutter, ISO)` specs — authored on the
   device and executed the same way every time, with the capture log written into the same folder as
   the frames rather than reconstructed later from EXIF. The pose is the expensive thing: a scene
   cannot be re-walked, because the second traversal's stations will not match the first.
2. **The motion axis.** Rolling shutter and motion blur need per-frame device motion, and RAW
   capture cannot coexist with ARKit on this platform. Recording the IMU stream alongside the frames
   is a capture-side problem, and no off-the-shelf app does it.

## Standalone by design

RAWForge defines its own on-disk format and is complete when its output is self-describing. No
consumer is designed for. [`photonforge`](https://github.com/tangericm/photonforge) — a linear-RAW
scene reconstruction and sensor-model pipeline — is the intended eventual reader, and will be fitted
to this format rather than the other way round. No decision here is settled by asking what something
downstream expects.

## How it behaves

**One directory per session**, in the app's own storage, frames and capture log inside it together.
Camera permission and nothing else — no photo library, no cloud. A session moves by dragging one
folder out of Files or off a cable.

**One failure rule.** A hard fault — motion over threshold, storage exhausted, thermal, capture
error, battery death — flags, aborts the **station**, and deletes that station's frames. Stations
already banked survive. A station either completed or never existed, so there is no partial state to
interpret later and no decision to make in the field.

Clipping is not a fault. Its statistics are recorded from the real Bayer payload and never judged on
device: that is a question about a scene, and the workstation answers it better.

## What the sensors actually do

Measured on an iPhone 15 Pro, not assumed — the numbers that constrain the design:

| Property | Finding |
|---|---|
| Format | True Bayer RAW on all three rear sensors; 12 MP only, 48 MP structurally unavailable |
| Zoom | 2x is the main sensor cropped, not a fourth camera — it cannot be captured in RAW at all. Setting `videoZoomFactor != 1.0` **succeeds silently and then kills the process at capture**, with no catchable error, so the app enforces the invariant itself |
| Useful ISO ceiling | ~8-9x each sensor's base ISO. Base ISO measured on device: **1x 55 · 0.5x 32 · tele 18** (hardware ceilings 12320 / 3072 / 2304) |
| Consequence | Above that ceiling Apple applies pure digital gain — **bracket with shutter, not ISO** |
| Exposure range | 1 s ceiling. Floor **advertised** as ~1/66,000 s by `minExposureDuration` on all three sensors — the earlier 1/2000 s figure did not come from the device. Whether a capture honours the advertised floor is unmeasured ([#14](https://github.com/tangericm/RAWForge/issues/14) item 4) |
| CFA pattern | Not uniform across the phone — 1x is BGGR while 0.5x and tele are RGGB, confirmed in-file on frames RAWForge wrote |
| Active area | `ImageWidth` 4224 against an `ActiveArea` of 4032 — 192 padding columns to crop. `DefaultCropSize` agrees independently. Note ImageIO reports the *cropped* 4032 and hides the padding |
| Opcodes | `OpcodeList1` and `2` are **absent** — nothing is owed before demosaic and nothing has been applied to the payload. `FixVignetteRadial` sits in list 3 (post-demosaic), plus `WarpRectilinear2` on the ultra-wide only |
| Black level | Scalar 528 (`BlackLevelRepeatDim 1 1`), identical on all three sensors. `WhiteLevel` 4095 — 12-bit linear in a 16-bit container, no linearization table |
| White balance | A locked WB reaches `AsShotNeutral` and **not the Bayer pixels** — measured at 1.00 where a pixel-level effect would have shown 9x. WB on this path is an annotation, not a transformation |
| Bracket depth | `maxBracketedCapturePhotoCount` is **8** on all three sensors, and an 8-frame Bayer bracket succeeds. Beyond 8, capture is sequential |
| Inter-frame gap | Hardware bracket: `max(33.4 ms, exposure)`. Sequential: 233-500 ms per frame, paid even when nothing changes between rungs |
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

## Non-goals

Not a consumer camera app. No editing, no filters, no ISP beyond what a viewfinder needs. No cloud,
no accounts. No pose estimation on device — structurally blocked by the RAW/ARKit exclusion.

## History

This repository previously held a Python RAW ISP pipeline. That work is preserved on the
[`isp-pipeline`](https://github.com/tangericm/RAWForge/tree/isp-pipeline) branch and tagged
[`v0-isp-pipeline`](https://github.com/tangericm/RAWForge/releases/tag/v0-isp-pipeline).

## License

Apache-2.0.
