# RAWForge

**An iPhone capture app for photometrically deterministic RAW — bracketed, undemosaiced Bayer
frames with metadata you can calibrate against, shot to a protocol instead of by hand.**

> **Status: charting.** Nothing is designed yet, let alone built. The open questions live on the
> project map: [`wayfinder:map`](https://github.com/tangericm/RAWForge/issues?q=label%3Awayfinder%3Amap).

---

## What this is

RAWForge is the capture end of [`photonforge`](https://github.com/tangericm/photonforge), which
reconstructs real scenes in linear RAW and renders them through a calibrated sensor model. That
pipeline is only as good as what goes into it, and what goes into it has hard requirements that
consumer camera apps do not state and cannot be assumed to hold:

- **True Bayer RAW, undemosaiced.** ProRAW is disqualified — it ships `NoiseReductionApplied = 0.95`,
  so the "clean" frame is already denoised and calibrating a noise model against it is circular.
- **Deterministic capture parameters.** Fixed white balance, known ISO and shutter, no per-frame
  adaptation, no zoom-dependent sensor switching.
- **Brackets that share a pose.** Exposure stacks from a fixed station, so the set can be joined
  back to one reconstructed camera.
- **Metadata that survives.** Black level, active area, CFA pattern and per-sensor identity carried
  through to the file, because the three iPhone sensors need three separate calibrations.

Off-the-shelf manual apps clear the format bar — Halide's Process Zero emits genuine undemosaiced
Bayer on all three rear sensors — but the protocol still lives in the photographer's head, and the
capture path is closed to anything the app's author did not anticipate.

## Why build it rather than keep shooting manually

Two things a third-party app cannot give:

1. **Protocol as code.** A bracket ladder, a station count and a shot list executed the same way
   every time, with the capture log written next to the frames rather than reconstructed later from
   EXIF. Capture mistakes are expensive — they are only discoverable after reconstruction.
2. **The motion axis.** Rolling shutter and motion blur need per-frame device motion, and RAW
   capture cannot coexist with ARKit on this platform. Recording the IMU stream alongside the frames
   is a capture-side problem, and it is the gate on `photonforge`'s stretch goals.

## What the sensors actually do

Measured on an iPhone 15 Pro, not assumed — the numbers that constrain the design:

| Property | Finding |
|---|---|
| Format | True Bayer RAW on all three rear sensors; 12 MP only, 48 MP structurally unavailable |
| Zoom | 2x is the main sensor cropped, not a fourth camera — it cannot be captured in RAW at all |
| Useful ISO ceiling | ~8-9x each sensor's base ISO (1x: 400-450 · 0.5x: 250-267 · 3x: 144-156) |
| Consequence | Above that ceiling Apple applies pure digital gain — **bracket with shutter, not ISO** |
| Exposure range | 1 s ceiling, 1/2000 s floor |
| White balance | Pinned to Daylight, for metadata determinism |
| `NoiseProfile` | A factor-of-2 sanity band, never a substitute for measured calibration |
| Pose | Must come from SfM — ARKit and RAW capture are mutually exclusive |

Sources: [`photonforge#2`](https://github.com/tangericm/photonforge/issues/2),
[`#20`](https://github.com/tangericm/photonforge/issues/20),
[`#22`](https://github.com/tangericm/photonforge/issues/22).

## Non-goals

Not a consumer camera app. No editing, no filters, no ISP — developing RAW is
`photonforge`'s problem, not this one. No cloud, no accounts.

## History

This repository previously held a Python RAW ISP pipeline. That work is preserved on the
[`isp-pipeline`](https://github.com/tangericm/RAWForge/tree/isp-pipeline) branch and tagged
[`v0-isp-pipeline`](https://github.com/tangericm/RAWForge/releases/tag/v0-isp-pipeline).

## License

Apache-2.0.
