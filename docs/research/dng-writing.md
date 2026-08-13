# DNG writing: AVFoundation's writer or a custom one, and does the metadata survive?

Research for [RAWForge#5](https://github.com/tangericm/RAWForge/issues/5) · parent map [RAWForge#1](https://github.com/tangericm/RAWForge/issues/1)
Researched 2026-08-08. Primary claims are from `developer.apple.com` and Adobe's DNG 1.7.1.0 specification. Third-party sources are marked **[3P]** and are corroboration only.

**The bar this is judged against.** Downstream integration is out of scope ([#13](https://github.com/tangericm/RAWForge/issues/13)). The writer is not evaluated against what any pipeline parses. It is evaluated against one test only: **can a reader holding just the file tell exactly what was captured and under what parameters?**

**Evidence labels used throughout.** Every claim is one of:

- **[DOC]** — stated by Apple or Adobe in a primary document. Cited.
- **[MEAS]** — measured by me on this machine from real iPhone 15 Pro DNGs. Reproducible.
- **[INF]** — inference. Flagged as such, never presented as fact.
- **[NOT ESTABLISHED]** — I could not settle it. Said plainly rather than papered over.

---

## Verdict

**Use AVFoundation's writer — `AVCapturePhoto.fileDataRepresentation()`. Do not build a custom DNG writer.**

The writer is not the weak link. Every photometric tag a sensor model depends on is present, correct, and per-sensor differentiated. On the specific question the ticket was opened to answer — *does the metadata a photometric calibration depends on survive the write?* — the answer is **yes, it survives**. Nothing in the tag-by-tag table below forces a custom writer.

Three qualifications, and one of them is serious:

1. **Use the modern API.** `dngPhotoDataRepresentation(forRawSampleBuffer:previewPhotoSampleBuffer:)` — the API the ticket names — was **deprecated in iOS 11** [DOC][avf-dng]. At an iOS 17.0 floor ([#6](https://github.com/tangericm/RAWForge/issues/6)) the correct call is `AVCapturePhoto.fileDataRepresentation()`, which Apple documents as returning DNG automatically for RAW photos [DOC][raw-guide]. The ticket's framing of "AVFoundation's writer" should be read as the modern one.

2. **A custom writer is not available anyway.** Image I/O cannot write DNG on iOS, so "custom" does not mean "use Apple's other writer" — it means vendoring a C/C++ DNG implementation. That cost is disproportionate to a problem the writer does not have. See [Custom-writer cost](#custom-writer-cost).

3. **The serious one: Apple's writer emits no unique frame id, and whether you can add one is undocumented.** This is the one place the self-description bar bites, and it got sharper when the capture log settled on *log ids as identity, filename as a derived rendering* — a renamed file then needs its own route back to its record. Whether a custom id can be embedded is **[NOT ESTABLISHED]**: there is a documented hook (`replacementMetadata(for:)`) that *might* work for DNG, and Apple documents nothing either way. It must be probed on device.

   **But this is not a blocker,** because there is a fallback that needs no writer cooperation and that I measured working: `DateTimeOriginal` + `SubsecTimeOriginal` gives a millisecond-resolved key that is unique across every frame in both multi-frame blocks tested (8/8, 16/16) [MEAS]. The log can join on it. Implement that regardless; treat the embedded id as an upgrade. See [Frame identity](#frame-identity-the-load-bearing-gap).

**What forces nothing but must be recorded elsewhere:** sensor *intent* (a 2x request is indistinguishable from 1x in the file), the capturing app's identity (`Software` holds the iOS version, not the app), and anything about the protocol — station, bracket, shot list. These are sidecar-log responsibilities regardless of writer choice.

---

## Provenance and method — read this before trusting the measurements

**What I measured.** 71 real iPhone 15 Pro DNGs at `C:\data\photonforge\captures\issue22\`, across all three rear sensors plus a 2x block and a dark-frame block. Device `iPhone16,1`, `Software` tag `26.5.2` (iOS 26.5.2), captured 2026-08-07.

**The caveat that matters.** These files were shot with **Halide Process Zero**, not by a harness calling `fileDataRepresentation()` directly. That is stated in the photonforge issue-22 capture record (`C:\data\photonforge\reports\issue22\issue22-resolution.md`, line 5), not inferred.

> **Closed 2026-08-13.** RAWForge now captures and writes its own frames through
> `fileDataRepresentation()`, and the measured values match: `PhotometricInterpretation = Color Filter
> Array`, BGGR on 1x, `BlackLevel` 528 scalar, `WhiteLevel` 4095, `ImageWidth` 4224 against
> `ActiveArea` 4032, `NoiseReductionApplied = 0/0`. The container is Apple's, confirmed rather than
> inferred, and every `[MEAS]` row below can be read as unqualified. See
> [#14](https://github.com/tangericm/RAWForge/issues/14).

So strictly, **I measured what Halide's output looks like, not what a direct AVFoundation call emits.** Two observations bear on whether that distinction bites, and both are inference, not proof:

- The `Software` tag reads `26.5.2` — the bare iOS version, with no application name. A hand-rolled writer would have little reason to stamp the OS version and omit itself. **[INF]**
- Halide is a third-party app with no private-API access, and Apple's Bayer RAW path terminates in `fileDataRepresentation()`. There is no other public route from a Bayer `AVCapturePhoto` to a DNG on iOS (see [Custom-writer cost](#custom-writer-cost) — Image I/O cannot write DNG). **[INF]**

Taken together these make it likely the container is Apple's. **But I did not verify it, and this project has been bitten by inferred behaviour before.** Every `[MEAS]` row below should be read as *"Apple's writer, as reached through Halide Process Zero"*. Confirming it costs one capture from a throwaway harness calling `fileDataRepresentation()` and one re-run of the dump script — that belongs on the device probe ([#14](https://github.com/tangericm/RAWForge/issues/14)).

**How I measured.** A hand-written TIFF/IFD walker (no exiftool on this machine) that enumerates every tag in IFD0, every SubIFD and the EXIF IFD, plus `tifffile` + `imagecodecs` to decode the lossless-JPEG Bayer tiles to pixels. Tag identities were checked against Adobe's DNG 1.7.1.0 spec rather than against a tag-name table — this caught two mislabels in my own first pass, one of which would have produced the wrong answer for sub-question 4. Scripts are in `%TEMP%` (`dngdump.py`, `dngscan.py`, `pdfgrep.py`); they are throwaway, not repo artefacts.

**Structure of the file, as measured.** Big-endian (`MM`) TIFF. IFD0 is a reduced-resolution JPEG preview (`NewSubFileType=1`, `PhotometricInterpretation=6`, 4032×3024) carrying the colour and camera-identity tags. The Bayer payload is in **SubIFD0**: `PhotometricInterpretation=32803` (CFA), 16-bit samples, `Compression=7`, tiled 264×378 in 128 tiles, 4224×3024. Apple states the writer "always writes compressed DNG files to save space" [DOC][wwdc16-501].

---

## Tag-by-tag survival table

The tags the ticket asks about, plus every other tag that bears on the self-description bar. `n=71` unless noted.

**Legend:** ✅ present and usable · ⚠️ present but qualified · ❌ absent

| Tag | # | Status | Value measured | Notes |
|---|---|---|---|---|
| `BlackLevel` | 50714 | ✅ | **528**, identical on all three sensors | `BlackLevelRepeatDim = [1,1]` — a single scalar, not a per-CFA-position pattern. A dark frame's *active-area* mean measures **527.26** against the declared 528 [MEAS] |
| `WhiteLevel` | 50717 | ✅ | **4095** | 12-bit, not 14. Payload is `uint16`; max sample observed 592 on a normal frame, 1083 on the ultra-wide |
| `ActiveArea` | 50829 | ✅ | 1x `[0,0,3024,4032]` · 0.5x **`[0,96,3024,4128]`** · 3x `[0,0,3024,4032]` | Per-sensor, and the ultra-wide's column-96 origin reproduces the map's constraint exactly |
| `CFAPattern` | 33422 | ✅ | 1x **`[2,1,1,0]` BGGR** · 0.5x `[0,1,1,2]` RGGB · 3x `[0,1,1,2]` RGGB | Reproduces the map's "1x is BGGR while 0.5x and 3x are RGGB on the same phone" |
| `CFARepeatPatternDim` | 33421 | ✅ | `[2,2]` | |
| `CFAPlaneColor` | 50710 | ✅ | `[0,1,2]` | |
| `NoiseProfile` | 51041 | ⚠️ | 1x `[1.365e-4, 2.575e-7]` · 0.5x `[2.811e-4, 3.174e-7]` · 3x `[1.756e-4, 4.432e-7]` | Present on all 71 and varies with sensor **and ISO**. But **count = 2, not 2×ColorPlanes** — one model for all planes, so no per-channel noise. Separately, photonforge measured Apple's declared `scale` disagreeing with measured gain by ~2× |
| `ColorMatrix1` | 50721 | ✅ | 9 SRATIONALs, per-sensor | `CalibrationIlluminant1` = **17** |
| `ColorMatrix2` | 50722 | ✅ | 9 SRATIONALs, per-sensor | `CalibrationIlluminant2` = **21**. The DNG spec does not enumerate these values — it states only that "the legal values for this tag are the same as the legal values for the LightSource EXIF tag" [DOC][dng-spec]. Under the EXIF enum 17 is Standard light A and 21 is D65; that mapping is EXIF's, not Adobe's, and I did not verify it against the EXIF standard itself |
| `AsShotNeutral` | 50728 | ✅ | e.g. 1x `[0.41873, 1.0, 0.57812]` | Green pinned to exactly 1.0. **A locked WB reaches it verbatim** — bit-identical across frames, vs drifting under auto WB (see sub-question 2, finding 2). Whether the gains also reach the Bayer *pixels* remains [#14](https://github.com/tangericm/RAWForge/issues/14)'s question |
| `ExposureTime` | 33434 (EXIF) | ✅ | e.g. `1/1010`, `1/125`, `1/499` | Exact rationals, not rounded |
| `ISOSpeedRatings` | 34855 (EXIF) | ✅ | 16 → 400+ observed | |
| `UniqueCameraModel` | 50708 | ✅ | `iPhone16,1 back camera` (43) · `iPhone16,1 back ultra wide camera` (14) · `iPhone16,1 back telephoto camera` (14) | **Distinguishes all three sensors.** Required tag per spec [DOC][dng-spec] |
| `LocalizedCameraModel` | 50709 | ❌ | absent in all 71 | Spec default is "same as `UniqueCameraModel`", so nothing is lost |
| `OpcodeList1` | 51008 | ❌ | absent in all 71 | |
| `OpcodeList2` | 51009 | ❌ | absent in all 71 | |
| `OpcodeList3` | **51022** | ⚠️ | **present in all 71** | `FixVignetteRadial` on every sensor; ultra-wide additionally gets `WarpRectilinear2`. Both flagged **mandatory**. See sub-question 4 |
| `DNGVersion` | 50706 | ⚠️ | **1.3.0.0** (57) · **1.6.0.0** (14) | Version varies *by sensor*: the 14 files at 1.6.0.0 are exactly the 14 ultra-wide files |
| `DNGBackwardVersion` | 50707 | ✅ | 1.3.0.0 on all 71 | |
| `BaselineExposure` | 50730 | ⚠️ | present in **56/71** | Omitted when it would be 0.0 (spec default). Absent ≠ unknown here |
| `MaskedAreas` | 50830 | ❌ | absent in all 71 | **Load-bearing.** No optical-black region is declared — and there is none in the pixels either. See sub-question 2 |
| `AnalogBalance` | 50727 | ❌ | absent | Spec default all-1.0 |
| `ForwardMatrix1/2` | 50964/5 | ❌ | absent | Optional; `ColorMatrix1/2` + illuminants are sufficient |
| `CameraCalibration1/2` | 50723/4 | ❌ | absent | Optional; identity assumed |
| `LinearizationTable` | 50712 | ❌ | absent | **Good news** — payload is already linear. Contrast ProRAW, where Apple says it writes one [DOC][wwdc21-10160] |
| `NoiseReductionApplied` | 50935 | ⚠️ | **`0/0`** on all 71 | Spec: `0/0` means **unknown**, *not* zero [DOC][dng-spec]. See sub-question 1 |
| `CameraSerialNumber` | 50735 | ❌ | absent | No device identity in the file beyond the model |
| `RawDataUniqueID` | 50781 | ❌ | absent | **No Apple-generated per-frame id.** See [Frame identity](#frame-identity-the-load-bearing-gap) |
| `DNGPrivateData` | 50740 | ❌ | absent | The spec-blessed custom-metadata slot, unused by Apple — so it is free |
| `ImageDescription` | 270 | ❌ | absent | Free |
| EXIF `UserComment` | 37510 | ❌ | absent | Free |
| XMP | 700 | ❌ | absent | Free |
| EXIF `ImageUniqueID` | 42016 | ❌ | absent | Free |
| `MakerNote` | 37500 (EXIF) | ⚠️ | present, 1611–1675 B, `"Apple iOS"` | Undocumented by Apple. `MakerNoteSafety` (50741) is **absent**, which per spec defaults to *unsafe* |
| `Software` | 305 | ⚠️ | **`26.5.2`** | The **iOS version**, not the capturing app. The file does not say what wrote it |
| `Make` / `Model` | 271/272 | ✅ | `Apple` / `iPhone 15 Pro` | |
| `ExposureProgram` | 34850 | ✅ | **1** = Manual | The file *does* record that exposure was manual |
| `ExposureMode` | 41986 | ✅ | **1** = Manual | |
| `WhiteBalance` | 41987 | ✅ | **1** = Manual | |
| `DateTimeOriginal` + `SubsecTimeOriginal` | 36867 / 37521 | ✅ | `2026:08:07 09:02:33` + `350` | **Millisecond** resolution; unique across 8/8 and 16/16 frames in two blocks. Best available de-facto frame key — see [Frame identity](#frame-identity-the-load-bearing-gap) |
| `LensModel` | 42036 | ✅ | `iPhone 15 Pro back camera 6.765mm f/1.78` | Second, independent sensor discriminator |
| `FocalLength` / `…In35mmFilm` | 37386 / 41989 | ✅ | 6.765 mm / 24 · 2.22 mm / 14 · (tele) | Third sensor discriminator |
| `DefaultCropOrigin` / `Size` | 50719/20 | ✅ | `[0,0]` / `[4032,3024]` | |
| `CFALayout` | 50711 | ❌ | absent | Defaults to 1 (rectangular) |
| `BaselineNoise`, `LinearResponseLimit`, `DefaultScale`, `BayerGreenSplit`, `ColorimetricReference`, `ProfileGainTableMap`, `ProfileName`, `Artist`, `Copyright`, ICC profile | — | ❌ | absent in all 71 | None load-bearing for Bayer calibration |

**Nothing in this table is "rewritten" in a way that loses information.** The ticket's worry — a writer that silently drops or normalises tags — does not materialise for the photometric set. The gaps that exist are gaps of *identity and intent*, not of photometry.

---

## Sub-question 1 — What does AVFoundation's writer actually emit?

**API.** The ticket names `dngPhotoDataRepresentation(forRawSampleBuffer:previewPhotoSampleBuffer:)`. Apple's page states it was **introduced in iOS 10.0 and deprecated in iOS 11.0**, with the replacement named explicitly [DOC][avf-dng]:

> In iOS 11 and later, implement the `photoOutput(_:didFinishProcessingPhoto:error:)` method in your capture delegate and use the `fileDataRepresentation()` method of the resulting `AVCapturePhoto` object.

At the iOS 17.0 floor, use `fileDataRepresentation()` [DOC][avf-fdr]. Apple's RAW guide is explicit that this yields DNG with no conversion step [DOC][raw-guide]:

> When you call `fileDataRepresentation()` on a RAW or Apple ProRAW photo, it automatically returns the data in the industry-standard DNG file format.

**Why DNG at all** — Apple chose it deliberately [DOC][wwdc16-501]:

> rather than introduce an Apple proprietary RAW file format, like so many other camera vendors do, we've elected to use Adobe's digital negative format for storage.

and warns it is a container, not a guarantee:

> DNG is a standard way of just storing bits and metadata. It doesn't imply a file format in any other way. […] a DNG is just like a standard box for holding ingredients. It's still up to individual RAW converters to decide how to interpret those ingredients.

**DNG version.** Apple documents none — the RAW guide says only "industry-standard DNG file format". Measured, it is **not a constant** [MEAS]: `DNGVersion` is `1.3.0.0` on 57 files and `1.6.0.0` on 14 — and the 14 are exactly the ultra-wide files. The mechanism is visible in the bytes: the ultra-wide is the only sensor that gets a `WarpRectilinear2` opcode, and `WarpRectilinear2` is a DNG 1.6.0.0 opcode [DOC][dng-spec]. The writer bumps the declared version to cover the opcodes it emits. `DNGBackwardVersion` stays `1.3.0.0` on all 71, so a 1.3-era reader is still told it may proceed.

**Undemosaiced?** Yes, unambiguously [MEAS]. SubIFD0 carries `PhotometricInterpretation = 32803` (CFA) with `SamplesPerPixel = 1` and a `CFAPattern`. Decoded, the payload is a single-plane 3024×4224 `uint16` Bayer mosaic. This is a container-level fact, not an inference.

**Linearised?** Yes — and this is the good outcome. `LinearizationTable` (50712) is **absent on all 71** [MEAS], so stored values are already linear; a reader applies `BlackLevel`/`WhiteLevel` and is done. Worth contrasting with ProRAW, where Apple says it *does* write one [DOC][wwdc21-10160]:

> **LinearizationTable** — which decompands the 12-bit stored data to linear scene values

The other ProRAW tags Apple names in that session — `BaselineSharpness`, `ProfileGainTableMap`, `ProfileToneCurve` — are all **absent** from these Bayer files [MEAS]. Apple's Bayer DNG is a markedly plainer object than its ProRAW DNG, which is exactly what this project wants.

**Opcode-corrected?** No — the payload is uncorrected and the corrections are attached as deferred instructions. See sub-question 4.

**One thing the writer gets wrong.** The ultra-wide's `WarpRectilinear2` opcode stamps its internal DNG-version field as **`1.3.0.0`** [MEAS], but the spec defines that opcode as **1.6.0.0** [DOC][dng-spec]. The spec's rule is:

> A DNG reader should never attempt to process an opcode with a version higher than DNG specification it was written to support.

By understating the version, Apple's writer invites a 1.3-only reader to process an opcode it cannot possibly understand. It does not affect RAWForge — nothing here applies opcodes — but it is a concrete instance of Apple's writer being non-conformant, and it argues for treating the opcode payload as data to record rather than instructions to trust.

**`NoiseReductionApplied = 0/0`, and what it does not say.** All 71 carry `0/0`. The spec is explicit [DOC][dng-spec]:

> A 0.0 value indicates that no noise reduction has been applied. […] A value of 0/0 indicates that this parameter is unknown.

The map's format constraint says ProRAW is disqualified because `NoiseReductionApplied = 0.95` makes calibration circular. That reasoning stands. But it is worth being precise: **Bayer does not assert 0.0 — it asserts *unknown*.** Apple declines to state that no noise reduction was applied. That is not evidence any was; `0/0` is also the spec default, so it may simply be a field Apple never fills. **[INF]** either way. The honest position is that this tag is silent on the Bayer path, and the map's confidence in Bayer's cleanliness rests on the *pixels* (photonforge's measurements) rather than on this tag.

---

## Sub-question 2 — Tag survival

The table above is the answer. Every tag the ticket lists is **present and per-sensor correct** except `LocalizedCameraModel` (absent, and harmless — the spec defaults it to `UniqueCameraModel`). No tag is rewritten or normalised in a way that destroys information.

Two findings the ticket did not ask for but that bear directly on calibration:

**1. There is no optical black anywhere in the file.** `MaskedAreas` (50830) is absent on all 71 [MEAS]. That alone would only mean "undeclared". But I decoded the pixels, and the region outside `ActiveArea` is **not** masked sensor data — it is **zero-filled** [MEAS]:

| Sensor | Payload | `ActiveArea` | cols 0–95 | cols 96–4031 | cols 4032–4223 |
|---|---|---|---|---|---|
| 1x main | 3024×4224 | `[0,0,3024,4032]` | mean **531.4** (active) | mean 532.4 (active) | mean **0.00** |
| 0.5x ultra-wide | 3024×4224 | `[0,96,3024,4128]` | mean **0.00** | mean 537.7 (active) | mean 265.1 — active to col 4127, then 0.00 |

The zeros line up exactly with the `ActiveArea` rectangle in both cases, including the ultra-wide's 96-column offset. So the 192 non-active columns are padding, not optical black.

**Consequence:** `BlackLevel` **cannot be verified from the file**. There are no masked pixels to measure it against, and the spec notes that when black has already been subtracted the masked pixels are no longer useful — but here they are simply absent. A reader must take `BlackLevel = 528` on trust. The one cross-check I can offer is measured: a dark frame's active-area mean reads **527.26** against the declared **528** [MEAS] — close, and slightly *below* the declared level, which means naive subtraction clips a little of the noise distribution to zero. Dark-frame calibration is not optional for this project; it is the only route to the black level. This corroborates photonforge issue-22's own note that dark frames are "mandatory for noise calibration since Apple exposes no `MaskedAreas`."

**2. The file records capture *mode* honestly, and `AsShotNeutral` tracks a locked white balance exactly.** This was not asked, but it is the cleanest evidence I found for the self-description bar, and it bears on a constraint the map currently flags as ⚠️ unverified.

Comparing the manual-WB and auto-WB blocks of the same scene [MEAS]:

| Block | EXIF `WhiteBalance` (41987) | `AsShotNeutral` across 3 frames |
|---|---|---|
| `block0_content` (WB locked) | **1** = Manual | `[0.41873, 1.0, 0.57812]` — **bit-identical on all three** |
| `block0_content_wbauto` (WB auto) | **0** = Auto | `[0.62697, …]` · `[0.63132, …]` · `[0.62812, …]` — **drifts every frame** |

Two things follow. First, a reader can tell from the file alone whether white balance was locked or auto — the mode is recorded, not merely implied. `ExposureProgram = 1` and `ExposureMode = 1` (both Manual) do the same job for exposure. Second, **a locked white balance reaches `AsShotNeutral` verbatim and deterministically**, with zero frame-to-frame variation.

That is a partial answer to the map's flagged-unverified row — *"Apple documents nothing about whether locked gains reach the Bayer pixels, reach `AsShotNeutral`, or are silently re-metered at capture."* It settles the `AsShotNeutral` limb: **the locked gains do reach `AsShotNeutral`, and are not re-metered.** It says nothing about whether they reach the Bayer *pixels* — that remains [#14](https://github.com/tangericm/RAWForge/issues/14)'s question and is not answerable from metadata. Caveat: this is Halide's WB lock, not RAWForge's `setWhiteBalanceModeLocked`, so it is evidence about the *device and writer*, not about the app's own control path.

**3. `NoiseProfile` is single-plane.** Count is **2**, not `2 × ColorPlanes` [MEAS]. The spec permits either [DOC][dng-spec]:

> Note that 𝑛 must be 1 (i.e., tag count is 2) or equal to the number of color planes […] When n = 1, the two specified parameters (𝑆1, 𝑂1) define the same noise model for all image planes.

So Apple gives one noise model for R, G and B together. Combined with photonforge's measured ~2× disagreement between the declared `scale` and measured gain, the map's existing position — *record it, never rely on it* — is the right one, and this measurement narrows why: it is both mis-scaled and under-specified.

---

## Sub-question 3 — Per-sensor identity

**Yes. A frame can be attributed to its physical sensor from the file alone, three independent ways.** [MEAS], n=71:

1. **`UniqueCameraModel` (50708)** — `iPhone16,1 back camera` / `iPhone16,1 back ultra wide camera` / `iPhone16,1 back telephoto camera`. Clean, distinct, and a **required** tag per spec [DOC][dng-spec], so it will not silently vanish.
2. **`LensModel` (42036)** — carries the focal length and aperture: `…6.765mm f/1.78` vs `…2.22mm f/2.2`.
3. **The calibration data itself** — `CFAPattern` (BGGR on 1x, RGGB on 0.5x/3x), `ActiveArea` (column-96 origin on the ultra-wide), `ColorMatrix1/2` and `NoiseProfile` all differ per sensor. Even with every identity string stripped, the sensor is recoverable from the numbers.

Given the map requires three separate calibrations and a station may span sensors ([#7](https://github.com/tangericm/RAWForge/issues/7)), this is the answer that was needed. **This sub-question is fully resolved and needs no probe.**

**One failure worth naming: sensor identity is not the same as capture intent.** The `block5_2x` files — captured while attempting 2x — are **indistinguishable in metadata from 1x frames**. Checked across all files in both blocks (n=4 for 2x, n=16 for 1x), every sensor-identifying field is identical [MEAS]:

| Block | `UniqueCameraModel` | `FocalLengthIn35mmFilm` | `ActiveArea` | `CFAPattern` | `LensModel` |
|---|---|---|---|---|---|
| `block2_main` (n=16) | `iPhone16,1 back camera` | 24 | `[0,0,3024,4032]` | `[2,1,1,0]` | `…6.765mm f/1.78` |
| `block5_2x` (n=4) | `iPhone16,1 back camera` | 24 | `[0,0,3024,4032]` | `[2,1,1,0]` | `…6.765mm f/1.78` |

This is consistent with the map's constraint that 2x cannot be captured in RAW at all — the request degraded to 1x — but the point for this ticket is that **the file records what happened, never what was asked for.** A reader cannot tell a deliberate 1x frame from a failed 2x attempt. That is a sidecar-log responsibility and cannot be fixed by any writer.

---

## Sub-question 4 — Opcode lists

**`OpcodeList3` (tag 51022) is present on all 71 files. `OpcodeList1` (51008) and `OpcodeList2` (51009) are absent on all 71.** [MEAS]

A correction to my own working, because it changes the answer: I initially had `OpcodeList3` at tag 51010 and read 51022 as an undocumented Apple-private tag. **That was wrong.** Adobe's spec assigns `OpcodeList3 = 51022 (C74E.H)` — the numbering skips from 51009 to 51022 [DOC][dng-spec]. Apple is using the standard tag, not a private one. Had I not checked against the spec I would have reported a private-tag finding that does not exist.

**Where each list sits in the pipeline** — Apple's own Image I/O documentation states it in the same terms as Adobe [DOC][cg-dng]:

| Constant | Apple's description |
|---|---|
| `kCGImagePropertyDNGOpcodeList1` | "The list of opcodes to apply to the raw image, as read directly from the file." |
| `kCGImagePropertyDNGOpcodeList2` | "The list of opcodes to apply to the raw image, after mapping it to linear reference values." |
| `kCGImagePropertyDNGOpcodeList3` | "The list of opcodes to apply to the raw image, after demosaicing it." |

**What is actually in them,** decoded from the bytes [MEAS]:

| Sensor | Opcodes | Parameters |
|---|---|---|
| **1x main** | `FixVignetteRadial` (id 3) | k0..k4 = `[3.2396, -4.1549, 11.2457, -14.1997, 7.0304]`, centre `(0.500175, 0.498313)` |
| **0.5x ultra-wide** | `WarpRectilinear2` (id 14) **then** `FixVignetteRadial` (id 3) | warp: N=1, kr0..kr4 = `[1.003484, 0, 0.115341, 0, -0.659395]`, radius range (0,1), centre `(0.5, 0.5)`, `reciprocalRadial=1`. vignette: k0..k4 = `[3.3654, 4.7727, 11.3054, -27.3820, 14.3737]`, centre `(0.502187, 0.503797)` |
| **3x telephoto** | `FixVignetteRadial` (id 3) | k0..k4 = `[0.2275, 0.1811, 0.4881, -1.4762, 0.8269]`, centre `(0.501652, 0.493060)` |

These are real, substantial, per-sensor corrections — not identity functions. The spec notes that if all kᵢ are zero the gain is identity [DOC][dng-spec]; these are far from it. The telephoto's coefficients are an order of magnitude smaller than the wide's, which is physically sensible for a longer lens.

**Is the payload pre- or post-opcode? Pre-opcode — the pixels are uncorrected.** This follows from the container, not from inference: the opcodes are *instructions to a reader*, and the absence of `OpcodeList1` and `OpcodeList2` means **no correction is specified to be applied before demosaic at all**. For RAWForge, which never demosaics, the practical reading is:

- **Vignetting is present in the stored Bayer data and is not corrected.** Apple hands you the correction to apply if you want it.
- **Geometric distortion is present and uncorrected**, on the ultra-wide only. This independently confirms the map's constraint that geometric distortion correction is never applied to RAW, and confirms distortion modelling belongs downstream.

**Two caveats, both flagged rather than smoothed over:**

1. **Both opcodes have `flags = 0`** [MEAS] — meaning bit 0 (optional) is clear, so per spec a reader is **not** permitted to skip them, and bit 1 (preview-skippable) is clear too. Apple is asserting these are mandatory. A calibration pipeline that ignores them is deviating from what the file says, deliberately. That is fine, but it should be a recorded decision rather than an oversight.
2. **`FixVignetteRadial` sitting in `OpcodeList3` is odd.** Vignetting is a per-pixel scalar gain, which is naturally a pre-demosaic operation — `OpcodeList2` is where you would expect it. Apple placing it post-demosaic means that applying it to an undemosaiced mosaic is *not* what the file specifies. Whether that matters numerically is **[NOT ESTABLISHED]** — for a radially symmetric gain it is likely near-equivalent, but I did not test it, and "likely" is not a finding.

**Does photonforge expect to apply them?** Out of scope — downstream integration was closed ([#13](https://github.com/tangericm/RAWForge/issues/13)). Against the self-description bar the answer is what matters: **the opcodes are fully recoverable from the file, so a reader can decide for itself.** That satisfies the bar. RAWForge should record that opcodes were present and leave them untouched.

---

## Sub-question 5 — Custom metadata in the DNG

Reframed per the coordinator's note, because the capture log now uses **log ids as identity and filename as a derived rendering**. The question is no longer "would it be nice to embed a station id" but **"if a file is renamed, can it still be traced to its log record?"**

### What Apple's writer leaves empty

All five candidate carriers are **absent on all 71 files** [MEAS]: `DNGPrivateData` (50740), `ImageDescription` (270), EXIF `UserComment` (37510), XMP (700), EXIF `ImageUniqueID` (42016). Good news in one sense — nothing to collide with. Bad news in another: **no evidence any of them survives a write**, because none was exercised.

Also absent: `RawDataUniqueID` (50781), so **Apple generates no per-frame unique id of its own** [MEAS].

### What the spec permits

`DNGPrivateData` is the spec-blessed slot, with three binding rules [DOC][dng-spec]:

> - The private data must start with a null-terminated ASCII string identifying the data. The first part of this string must be the manufacturer's name, to avoid conflicts between manufacturers.
> - The private data must be self-contained. All offsets within the private data must be offsets relative to the start of the private data […]
> - The private data must be byte-order independent.

A short ASCII payload such as `RAWForge\0{"frame":"…"}` satisfies all three trivially. Apple exposes a matching Image I/O constant, `kCGImagePropertyDNGPrivateData`, described as "Private data that manufacturers may store with an image and use in their own converters" [DOC][cg-dng].

### The documented hook, and its exact limit

`AVCapturePhoto.fileDataRepresentation(with:)` (iOS 12.0+) takes an `AVCapturePhotoFileDataRepresentationCustomizer` [DOC][avf-fdr-custom], whose `replacementMetadata(for:)` callback is documented as [DOC][avf-replmeta]:

> **Declaration:** `optional func replacementMetadata(for photo: AVCapturePhoto) -> [String : Any]?`
>
> A callback in which you can provide replacement metadata or direct `AVCapturePhoto` to strip existing metadata from the flattened file. […] If your delegate doesn't implement this callback, the existing metadata in the in-memory `AVCapturePhoto` container is written directly to the file data representation.

The dictionary is "a dictionary of keys and values from `CGImageProperties`" — the same namespace as `kCGImagePropertyDNGPrivateData` and `kCGImagePropertyExifUserComment`. On paper the route exists: return `photo.metadata` plus your own key.

`AVCapturePhoto.metadata` itself is **read-only** (`{ get }`) [DOC][avf-metadata], so the customizer is the only documented write path.

**And here is where it stops.** Apple's documentation does **not** state:

- whether `replacementMetadata(for:)` is honoured at all on the **RAW/DNG** path, as opposed to JPEG/HEIF. The protocol's only RAW-specific member is `replacementAppleProRAWCompressionSettings(…)`, which is about compression and is **ProRAW-only** [DOC][avf-fdr-custom]. Bayer RAW gets no named member.
- whether an *added* key (as opposed to a modified standard one) is written through rather than dropped;
- whether `kCGImagePropertyDNGPrivateData` in particular is writable, or read-only in practice;
- whether the deprecated `dngPhotoDataRepresentation` route's "attach metadata to the sample buffer" mechanism [DOC][avf-dng] has any modern equivalent.

I searched Apple's documentation, the RAW/ProRAW guide, WWDC16-501 and WWDC21-10160 for a statement either way and found none. WWDC16-501 discusses embedding a *thumbnail* in the DNG and nothing else:

> Another great use of the preview image is as an embedded thumbnail in your high-quality JPEG or DNG files. […] Embedding a thumbnail image is always a good idea because you don't know where it's going to be viewed.

**Verdict on sub-question 5: [NOT ESTABLISHED].** There is a documented API that plausibly does this, no documented statement that it works for DNG, and no measurement — the sample files could not test it because they were not written by RAWForge. I am not going to call it a yes. **It is a one-hour on-device probe and it should go on [#14](https://github.com/tangericm/RAWForge/issues/14) as a blocking item**, because the log design now depends on the answer.

---

## Frame identity — the load-bearing gap

Spelled out separately because it is the one place the writer fails the self-description bar, and because the log's *ids-are-identity* decision makes it consequential.

**The failure.** If a DNG is renamed, detached from its directory, or re-sorted, **there is currently no field in it that points back to its log record.** `RawDataUniqueID` is absent, `Software` names the OS rather than the app, and no user field is populated. [MEAS]

**Three routes, in the order they should be tried:**

**1. Embed an explicit id via `replacementMetadata(for:)`.** The right answer if it works. `DNGPrivateData` is the most spec-correct target; EXIF `UserComment` or `ImageDescription` are more likely to survive third-party round-trips but are less semantically honest. **Blocked on the probe above.**

**2. Fall back to the timestamp as a natural key.** `DateTimeOriginal` + `SubsecTimeOriginal` gives **millisecond** resolution [MEAS] — `SubsecTimeOriginal` is three digits, e.g. `2026:08:07 09:02:33` + `350`. The capture log can record the same instant and join on it. This needs **no writer support at all**, which is its great virtue.

**Measured, and it holds.** Whole seconds alone are *not* sufficient — in `block1_repeat`, frames `1-1` and `1-2` both read `08:26:22`. But adding sub-seconds separates them cleanly, and across both multi-frame blocks the composite key is fully unique [MEAS]:

| Block | Frames | Distinct `(DateTimeOriginal, SubsecTimeOriginal)` | Collisions |
|---|---|---|---|
| `block1_repeat` | 8 | **8** | none |
| `block2_main` | 16 | **16** | none |

e.g. `08:26:22.127`, `08:26:22.904`, `08:26:23.657` — sub-second digits resolve the same-second pair.

**The limit of that test, stated honestly.** These frames are **0.7–1.3 s apart** — sequential single captures, not a hardware bracket. So the measurement shows the key is well-formed and millisecond-resolved, but it does **not** prove uniqueness under a fast `AVCapturePhotoBracketSettings` burst, where frames may be tens of milliseconds apart. A sub-millisecond collision is implausible but **[NOT ESTABLISHED]**. Re-run this check against a real bracket during the device probe.

If it ever did collide, the composite (`DateTimeOriginal`+`SubsecTimeOriginal`, `UniqueCameraModel`, `ExposureTime`, `ISOSpeedRatings`) would almost certainly disambiguate, since the ladder varies shutter by design — but that is **[INF]**, not measured.

**3. Accept filename-as-identity for the file and treat the log as authoritative.** The status quo the log design explicitly moved away from. Worth stating that if routes 1 and 2 both fail, this is where it lands, and the cost is that a renamed file is orphaned.

**Recommendation:** probe route 1; implement route 2 unconditionally regardless of the outcome, because it is free and it is the only route that survives a writer that silently drops custom keys. Belt and braces here is cheap.

---

## Custom-writer cost

**Recommendation: do not build one.** Not because it is impossible, but because the writer is not the problem, and the alternatives are worse than they look.

**Image I/O cannot write DNG on iOS.** This kills the cheapest imaginable "custom" route — using Apple's own general-purpose image writer. Apple documents `CGImageDestinationCopyTypeIdentifiers` as the runtime source of truth for writable UTIs and does **not** document DNG either way [DOC][cg-dest]. What exists is developer-reported: two Apple Developer Forums threads report the identical failure, with the exact error text [3P]:

> `findWriterForTypeAndAlternateType:119: *** ERROR: unsupported output file format 'com.adobe.raw-image'`
> `CGImageDestinationCreateWithURL:4429: *** ERROR: CGImageDestinationCreateWithURL: failed to create 'CGImageDestinationRef'`

— from a June 2024 thread attempting exactly this (round-tripping a DNG to edit its metadata) [3P][fo-758433], and the analogous `'public.camera-raw-image'` failure in an April 2022 thread [3P][fo-705221]. **Neither thread received an Apple reply.** So: strongly corroborated by two independent reports, formally **undocumented by Apple**. Treat as "almost certainly true, unverified by me — I have no iOS device here to run `CGImageDestinationCopyTypeIdentifiers` against."

This also has a second consequence worth noting: **you cannot post-process the DNG on-device to inject metadata after the fact.** If `replacementMetadata` does not work, there is no Image I/O second bite. That raises the stakes on the probe.

**What "custom" would therefore mean.** Vendoring a C/C++ TIFF/DNG implementation into the app:

- **Adobe DNG SDK** — the reference implementation, and the only thing that produces guaranteed-conformant output.
  - **Version and licence — partly established, and the licence is not the obstacle.** The current SDK is **1.7.1, Build 2611, released 2026-06-09**, and the licence grant is strikingly permissive: a "non-exclusive, worldwide, royalty free license to use, reproduce, prepare derivative works from, publicly display, publicly perform, distribute and sublicense the Software for any purpose", subject to retaining copyright notices [adobe-dng], [adobe-eula]. That is compatible with a closed-source app. **Confidence caveat:** these came back through a domain-restricted web search over `adobe.com`; my direct fetches of both `helpx.adobe.com/camera-raw/digital-negative.html` and the EULA page **timed out**, so I did not read the licence text with my own eyes. Verify before relying on it.
  - **iOS buildability — [NOT ESTABLISHED], and this is the decisive unknown.** Adobe publishes separate EULA pages for **Mac and Windows only**; iOS is not mentioned anywhere I could reach [adobe-eula]. I could not confirm whether the SDK ships Xcode projects or CMake, whether its platform macros (historically `qMacOS`/`qWinOS`) admit an iOS/arm64 target, or whether any maintained iOS port exists.
  - **Dependencies — [NOT ESTABLISHED].** Historically XMP toolkit, expat, zlib and libjpeg. DNG 1.7 additionally adds JPEG XL [DOC][dng-spec], which implies a **libjxl** dependency for full conformance and a correspondingly unpleasant iOS build. I did not verify the actual dependency list of Build 2611.
- **libtiff** — would handle the TIFF container, but every DNG-specific tag would still be hand-assembled, and the opcode lists are big-endian-regardless-of-file-byte-order [DOC][dng-spec], which is exactly the kind of detail that produces subtly broken files. **[NOT ESTABLISHED]** whether it builds for iOS today, though it is widely reported to.
- **Hand-rolled TIFF/EP** — genuinely feasible in the narrow sense: I wrote a complete DNG *reader* for this investigation in an afternoon, and writing is the easier direction. But a writer must also **compress the Bayer payload**. Apple's files are tiled lossless JPEG (`Compression = 7`, 128 tiles of 264×378) [MEAS], and Apple states the API "always writes compressed DNG files to save space" [DOC][wwdc16-501]. Writing uncompressed DNG instead would roughly double file size on a device where storage is the binding constraint for a long shoot; writing lossless JPEG means vendoring an encoder anyway.

**The decisive argument is not cost, it is risk.** A custom writer would have to reproduce, correctly and per-sensor, everything in the survival table above: three `ColorMatrix` pairs, three `ActiveArea` rectangles, three `CFAPattern`s, ISO-dependent `NoiseProfile`s and per-sensor opcode lists. Apple already emits all of it correctly. Hand-rolling that is a large surface area of new, uncalibrated bugs in exchange for **one field** — a frame id — that the documented customizer may well provide for free.

**And the ticket's own escape clause does not trigger.** Sub-question 6 is conditional: *"If AVFoundation's writer is inadequate."* On the photometric metadata the ticket was actually worried about, it is not inadequate. It is good.

**If the frame-id probe fails**, the proportionate response is a sidecar (a per-frame JSON beside the DNG, or the capture log carrying the timestamp key), **not** a custom writer. A sidecar costs a few dozen lines. A custom writer costs a vendored C++ dependency, an iOS build fight, and permanent responsibility for DNG conformance.

---

## What I could not establish

Stated plainly, because inferring past these is exactly what this project has been burned by.

1. **That the measured files came from `fileDataRepresentation()`.** They came from Halide Process Zero. The container is very likely Apple's, for the reasons given, but it is **[INF]**. One harness capture settles it.
2. **Whether `replacementMetadata(for:)` reaches the DNG path at all.** Apple documents nothing. Undocumented, untested, and now load-bearing for the log design.
3. **Whether the timestamp key survives a *fast* bracket.** Now partly closed: `(DateTimeOriginal, SubsecTimeOriginal)` is unique across 8/8 and 16/16 frames in two blocks [MEAS]. But those frames are 0.7–1.3 s apart, so this does not test a hardware `AVCapturePhotoBracketSettings` burst where inter-frame gaps may be tens of milliseconds. Re-check on the probe.
4. **Adobe DNG SDK: whether it builds for iOS, and its dependency set.** Version (1.7.1 Build 2611, 2026-06-09) and a permissive licence grant are *probably* settled but came from a search summary, not a page I successfully fetched — adobe.com timed out twice. iOS buildability is genuinely unknown, and Adobe publishes Mac and Windows EULAs only. The custom-writer verdict is *don't*, so this gap does not change the recommendation — but it would need closing if the verdict were revisited.
5. **libtiff's current iOS build status** and how much DNG tag knowledge it ships.
6. **Whether `CGImageDestination` truly refuses DNG on iOS 17+.** Two forum reports say so, Apple says nothing, and I have no device to run `CGImageDestinationCopyTypeIdentifiers` against.
7. **Whether applying `FixVignetteRadial` to an undemosaiced mosaic is numerically equivalent** to applying it post-demosaic as the file specifies. Probably close for a radially symmetric gain — but untested, and "probably" is not a finding.
8. **What Apple's 1611–1675-byte `MakerNote` contains.** Undocumented by Apple. It may carry per-frame capture state worth having; I did not reverse-engineer it. `MakerNoteSafety` is absent, so the spec's default is that it is *unsafe* to preserve across edits.
9. **Whether `dngPhotoDataRepresentation` and `fileDataRepresentation()` produce byte-identical containers.** Irrelevant given the deprecation, but unverified.

---

## Sources

**[Primary — Apple]**

- [avf-dng] `AVCapturePhotoOutput.dngPhotoDataRepresentation(forRawSampleBuffer:previewPhotoSampleBuffer:)` — https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/dngphotodatarepresentation(forrawsamplebuffer:previewphotosamplebuffer:)
- [avf-fdr] `AVCapturePhoto.fileDataRepresentation()` — https://developer.apple.com/documentation/avfoundation/avcapturephoto/filedatarepresentation()
- [avf-fdr-custom] `AVCapturePhotoFileDataRepresentationCustomizer` — https://developer.apple.com/documentation/avfoundation/avcapturephotofiledatarepresentationcustomizer
- [avf-replmeta] `replacementMetadata(for:)` — https://developer.apple.com/documentation/avfoundation/avcapturephotofiledatarepresentationcustomizer/replacementmetadata(for:)
- [avf-metadata] `AVCapturePhoto.metadata` — https://developer.apple.com/documentation/avfoundation/avcapturephoto/metadata
- [raw-guide] Capturing photos in RAW and Apple ProRAW formats — https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats
- [avf-bayer] `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)` (iOS 14.3+) — https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isbayerrawpixelformat(_:)
- [avf-rawtypes] `AVCapturePhotoOutput.availableRawPhotoFileTypes` — https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotofiletypes
- [cg-dng] DNG Image Properties (Image I/O) — https://developer.apple.com/documentation/imageio/dng-image-properties
- [cg-dest] `CGImageDestination` — https://developer.apple.com/documentation/imageio/cgimagedestination
- [wwdc16-501] WWDC16 session 501, "Advances in iOS Photography" — https://developer.apple.com/videos/play/wwdc2016/501/
- [wwdc21-10160] WWDC21 session 10160, "Capture and process ProRAW images" — https://developer.apple.com/videos/play/wwdc2021/10160/

**[Primary — Adobe]**

- [dng-spec] Digital Negative (DNG) Specification 1.7.1.0, September 2023 — https://helpx.adobe.com/content/dam/help/en/photoshop/pdf/DNG_Spec_1_7_1_0.pdf
  - `UniqueCameraModel` p. 25 · `DNGPrivateData` p. 41 · `ActiveArea` / `MaskedAreas` p. 44 · `NoiseReductionApplied` p. 49 · `OpcodeList1/2/3` p. 58 · `NoiseProfile` p. 59 · Opcode List Processing ch. 7 p. 105 · `FixVignetteRadial` p. 110 · `WarpRectilinear2` p. 120
- [adobe-dng] DNG landing page (SDK version and download) — https://helpx.adobe.com/camera-raw/digital-negative.html — ⚠️ **direct fetch timed out**; SDK version 1.7.1 Build 2611 / 2026-06-09 reached only via search summary, unverified by me
- [adobe-eula] DNG SDK License Agreement — https://www.adobe.com/support/downloads/dng/dng_sdk_eula_win.html (Mac variant: https://www.adobe.com/support/downloads/dng/dng_sdk_eula_mac.html) — ⚠️ **direct fetch timed out**; licence grant wording reached only via search summary, unverified by me
- Adobe DNG SDK security page — https://helpx.adobe.com/security/products/dng-sdk.html

**[MEAS] Measured on this machine**

- 71 iPhone 15 Pro DNGs at `C:\data\photonforge\captures\issue22\` — blocks `0_content`, `0_content_wbauto`, `1_repeat`, `2_main`, `3_ultrawide`, `4_tele`, `5_2x`, `7_dark`. Device `iPhone16,1`, iOS 26.5.2, captured 2026-08-07 with **Halide Process Zero**.
- Capture provenance: `C:\data\photonforge\reports\issue22\issue22-resolution.md`
- Tooling: hand-written TIFF/IFD walker + opcode-list decoder; `tifffile` 2026.7.14 with `imagecodecs` 2026.6.26 for lossless-JPEG tile decoding; `pypdf` 6.14.2 for spec extraction. No exiftool on this machine.

**[3P]** Corroboration only — Apple-hosted but user-generated, or non-Apple. **No Apple staff replied to either thread.**

- [fo-758433] "Updating metadata properties of a DNG (or other) format image", Apple Developer Forums, Jun 2024 — https://developer.apple.com/forums/thread/758433
- [fo-705221] "How to create CGImageDestinationRef with type kUTTypeRawImage?", Apple Developer Forums, Apr 2022 — https://developer.apple.com/forums/thread/705221
