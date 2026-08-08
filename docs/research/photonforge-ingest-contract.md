# Output contract: what does `photonforge` ingest actually read?

Resolves [RAWForge#3](https://github.com/tangericm/RAWForge/issues/3). Date: 2026-08-08.

## The headline finding, stated first

**`photonforge` has no ingest code. It has no source code at all.**

```
$ gh api repos/tangericm/photonforge --jq '{language, size}'
{"language": null, "size": 99}

$ git ls-tree -r --name-only origin/main          # photonforge @ 29342bd
.gitignore
CLAUDE.md
LICENSE
README.md
docs/agents/domain.md
docs/agents/issue-tracker.md
docs/agents/triage-labels.md
```

All five research branches (`research/{gsplat,noise-calibration,pose-recovery,prior-art,raw-format}`)
add exactly one Markdown file each and nothing else. There is no `src/`, no package, no loader, no
`CONTEXT.md`, no `docs/adr/`. The repo's own README says so: *"**Status: charting.** Nothing is
designed yet, let alone built."* (`photonforge/README.md:6`).

So the ticket's framing — "read the ingest/loader code path" — has no code to read in the subject
repo, and **every element of the contract is `planned`, none is `implemented in photonforge`.**

That does *not* make the contract vacuous, because `photonforge`'s own closed research ticket
[pf#6](https://github.com/tangericm/photonforge/issues/6) commits it to adopting a *named, existing*
reference implementation verbatim:

> **This filename-stem join is the whole mechanism of "pose transfer".** There is no clever
> registration step. **Adopt the same convention in `photonforge`.**
>
> — `photonforge/docs/research/pose-recovery.md:88` (branch `research/pose-recovery`, `7e97dba`)

That reference — Google Research's `multinerf`, the RawNeRF release — *is* real, readable code, and
it is the only executable definition of the contract that exists anywhere. This document therefore
grades every element on **three** axes, and never blurs them:

| Tag | Meaning |
|---|---|
| **[PF-PLAN]** | Appears only in a `photonforge` doc or issue. No code exists, in any repo. |
| **[REF-IMPL]** | Implemented in `multinerf` — the reference `photonforge` has committed to adopting. Real code, cited by file:line. Binding on `photonforge` only to the extent pf#6 says "adopt this". |
| **[MEASURED]** | Verified by me from the actual iPhone 15 Pro DNGs on disk at `C:\data\photonforge\`. Device fact, not a plan. |

Nothing in this document is tagged "implemented in `photonforge`", because nothing is.

### Sources used

| Source | Location |
|---|---|
| `photonforge` repo | `C:\Users\erict\OneDrive\Desktop\Projects\photonforge` (local clone, fetched; matches `origin`) |
| `photonforge` research docs | branches `research/*`, one `docs/research/<topic>.md` each |
| `photonforge` issues | `gh issue view N -R tangericm/photonforge` |
| `multinerf` `raw_utils.py`, `datasets.py` | fetched from `raw.githubusercontent.com/google-research/multinerf/main/internal/` |
| RawNeRF release dataset | `C:\data\photonforge\datasets\rawnerf\scenes\` — the concrete on-disk layout |
| iPhone 15 Pro DNGs | `C:\data\photonforge\datasets\{0.5x,1x,2x,3x}.DNG`, `C:\data\photonforge\captures\issue22\` |
| exiftool 13.59 | `C:\data\photonforge\tools\exiftool\` (its Perl source read as a primary source) |

---

## 1. The output contract, as a checklist

What `RAWForge` must emit for a `photonforge` ingest to succeed **unmodified** — meaning, today,
"for the `multinerf` loader pf#6 commits to adopting to run without edits".

### 1.1 Per-frame files

- [ ] **`<stem>.dng`** — one DNG per captured frame. **[REF-IMPL]** `raw_utils.py:175`
- [ ] **`<stem>.json`** — an `exiftool -json` dump of that same DNG, sitting beside it, same stem.
      **[REF-IMPL]** `raw_utils.py:177-178`, `raw_utils.py:221`
- [ ] The JSON's top level must be a **one-element array** (exiftool's default `-json` shape) —
      the loader does `json.load(f)[0]`. **[REF-IMPL]** `raw_utils.py:178`
- [ ] **`<stem>.JPG`** in a sibling `images/` directory — the display-referred proxy COLMAP is run
      on. Extension need not match the DNG's. **[REF-IMPL]** `raw_utils.py:174`, `datasets.py:617`

### 1.2 Metadata that must be present in the DNG

Hard-required by the reference loader (absence ⇒ crash or wrong result):

- [ ] **`BlackLevel`** — and it must be a **scalar**, not a 4-vector. **[REF-IMPL]** `raw_utils.py:201, 355`
- [ ] **`WhiteLevel`** — scalar. **[REF-IMPL]** `raw_utils.py:202, 356`
- [ ] **`AsShotNeutral`** — 3 values. **[REF-IMPL]** `raw_utils.py:203, 257`
- [ ] **`ColorMatrix2`** — 9 values. **[REF-IMPL]** `raw_utils.py:204, 261`
- [ ] **`ShutterSpeed`** — **string, literally of the form `1/N`**. See §4 and gap **G3**; this one
      collides with RAWForge's locked 1 s exposure ceiling. **[REF-IMPL]** `raw_utils.py:250-252`

Read if present, tolerated if absent:

- [ ] **`NoiseProfile`** — in the key list, but every consumer is diagnostic. **[REF-IMPL]** `raw_utils.py:205`; **[PF-PLAN]** `raw-format.md:465`

Required by `photonforge`'s stated plans but **read by nothing today**:

- [ ] `CFAPattern` / `CFAPattern2`, `ActiveArea`, `ColorMatrix1`, `NoiseReductionApplied`,
      `BitsPerSample`, `ISO` **[PF-PLAN]** `raw-format.md:453-454`
- [ ] `UniqueCameraModel` — the only tag that distinguishes the three sensors. **[MEASURED]** distinct
      on all three; **[PF-PLAN]** nothing reads it (see §6)

Format gate (disqualifiers, not requirements):

- [ ] `NoiseReductionApplied` absent/`undef` — `0.95` means ProRAW and the frame is disqualified.
      **[PF-PLAN]** pf#2; **[MEASURED]** `undef` on all three Process Zero sensors
- [ ] `PhotometricInterpretation = Color Filter Array`, `SamplesPerPixel = 1`,
      `ProfileGainTableMap` absent. **[PF-PLAN]** pf#20 discriminators; **[MEASURED]** all pass

### 1.3 Directory layout

- [ ] One directory per scene, containing `raw/`, `images/`, `sparse/0/`. **[REF-IMPL]**
      `datasets.py:580`, `raw_utils.py:305`; **[MEASURED]** on disk, §7
- [ ] `raw/` is **flat** — `<stem>.dng` and `<stem>.json` interleaved, no subdirectories.
      **[REF-IMPL]** `raw_utils.py:182-185`
- [ ] Full resolution, never downsampled, in raw mode. **[REF-IMPL]** `datasets.py:571-573`

**Conflict:** `photonforge`'s own preferred layout is *per-station subdirectories*
(`station_0001/raw/{ev-2,ev0,ev+2}.dng`) — **[PF-PLAN]** `pose-recovery.md:566-568` — which is a
different shape from the flat `raw/` the reference implements. Unresolved; see **G6**.

### 1.4 Grouping

- [ ] The join key is the **filename stem**, and nothing else. **[REF-IMPL]** `raw_utils.py:174`;
      **[PF-PLAN]** `pose-recovery.md:88`
- [ ] Bracket membership is expressed **only** by shared shutter-speed values being distinct
      (`exposure_idx` is derived from unique shutter speeds, not from any declared grouping).
      **[REF-IMPL]** `raw_utils.py:340-348`
- [ ] Station identity has **no on-disk representation at all** in the reference. **[REF-IMPL]**
      absent; **[PF-PLAN]** carried by directory name, `pose-recovery.md:566-568`

### 1.5 Capture log / sidecar

- [ ] **No capture log is read. There is no schema. No issue proposes one.** The only sidecar is the
      per-frame exiftool dump of the DNG's own tags — a *re-serialisation of the frame*, not an
      independent record of the shoot. See §5 and gap **G5**.

---

## 2. Sub-question 1 — File formats accepted

**DNG only, opened through `rawpy` (LibRaw). [REF-IMPL]**

```python
# multinerf/internal/raw_utils.py:173-178
def load_raw_exif(image_name):
    base = os.path.join(image_dir, os.path.splitext(image_name)[0])
    with utils.open_file(base + '.dng', 'rb') as f:
      raw = rawpy.imread(f).raw_image
    with utils.open_file(base + '.json', 'rb') as f:
      exif = json.load(f)[0]
    return raw, exif
```

The extension is **hardcoded lowercase `.dng`** (`raw_utils.py:175`), and discovery globs
`'*.dng'` (`raw_utils.py:184`). iOS writes `.DNG` uppercase, and `photonforge`'s own shot list says
*"Keep Halide's filenames"* (`shot-list.md:232`). On a case-insensitive Windows filesystem this is
invisible; on Linux it is a silent empty-dataset. **RAWForge should emit lowercase `.dng`, or the
constraint must be recorded as a downstream fix.**

Loader-imposed constraints that follow from `rawpy.imread(f).raw_image`:

- `.raw_image` is the **full, uncropped** sensor array — margins and padding included. LibRaw's
  cropped view is `.raw_image_visible`, which is *not* used. This is gap **G2**.
- It returns the mosaic as-is; no `ActiveArea` crop, no `LinearizationTable` application, no
  orientation handling.

No DNG version is checked anywhere. **[MEASURED]** the device is inconsistent about it: `DNGVersion`
is `1.3.0.0` on the 1x and 3x DNGs but `1.6.0.0` on the 0.5x — from the same phone, same session.
Nothing reads the tag, so it does not matter today, but it means **RAWForge cannot promise a single
DNG version across sensors if it writes via AVFoundation the way Halide does.**

`photonforge`'s planned capture stack specifies the write path: `AVCapturePhoto.fileDataRepresentation()`
to `.dng`, from `kCVPixelFormatType_14Bayer_*`, with `isAppleProRAWEnabled = false`
**[PF-PLAN]** `raw-format.md:441-443`.

---

## 3. Sub-question 2 — Required metadata

### 3.1 The reference's actual key list

```python
# multinerf/internal/raw_utils.py:197-206
# Relevant fields to extract from raw image EXIF metadata.
_EXIF_KEYS = (
    'BlackLevel',      # Black level offset added to sensor measurements.
    'WhiteLevel',      # Maximum possible sensor measurement.
    'AsShotNeutral',   # RGB white balance coefficients.
    'ColorMatrix2',    # XYZ to camera color space conversion matrix.
    'NoiseProfile',    # Shot and read noise levels.
)
```

**That is the entire list.** Five tags, plus `ShutterSpeed` handled as a special case.

**Tolerated if absent.** The extraction loop skips missing keys silently:

```python
# multinerf/internal/raw_utils.py:238-241
for key in _EXIF_KEYS:
    exif_value = exif.get(key)
    if exif_value is None:
      continue
```

But "tolerated" is misleading for four of the five — the loop is the only place absence is
survivable. Downstream, `meta['BlackLevel']` and `meta['WhiteLevel']` are indexed unconditionally
(`raw_utils.py:355-356`), as are `meta['AsShotNeutral']` (`:257`) and `meta['ColorMatrix2']` (`:261`).
Missing any of those four raises `KeyError`. **Only `NoiseProfile` is genuinely optional.**

**Not read at all:** `CFAPattern`, `ActiveArea`, `ColorMatrix1`, `ISO`, `BaselineExposure`,
`Orientation`, `LinearizationTable`, `DefaultCropOrigin/Size`, `NoiseReductionApplied`,
`UniqueCameraModel`, `BitsPerSample`. Note especially: **the reference never reads ISO in raw mode.**
(It reads `ISOSpeedRatings` only on the non-raw JPEG path, `datasets.py:634-639`.)

### 3.2 Shape constraints, which are the sharp edge

`BlackLevel`/`WhiteLevel` are reshaped assuming **one scalar per image**:

```python
# multinerf/internal/raw_utils.py:355-357
blacklevel = meta['BlackLevel'].reshape(-1, 1, 1)
whitelevel = meta['WhiteLevel'].reshape(-1, 1, 1)
images = (raws - blacklevel) / (whitelevel - blacklevel) * shutter_ratio
```

**[MEASURED]** the iPhone 15 Pro emits `BlackLevel: 528`, `WhiteLevel: 4095` — plain scalars, on all
three sensors. Compatible. **But** a DNG may legally carry a 4-element per-CFA-plane `BlackLevel`,
which exiftool would render as `"528 528 528 528"`; the string branch (`raw_utils.py:246-248`) would
parse it to 4 floats per image and `reshape(-1,1,1)` would yield `(4N,1,1)`, broadcasting wrongly
against `(N,H,W)`. Since `photonforge`'s noise work explicitly wants **per-CFA-plane** treatment
(`noise-calibration.md:11`: *"per ISO and per CFA plane (R, Gr, Gb, B)"*), this is a live risk if
RAWForge writes its own DNGs rather than mirroring Apple's. **Contract item: emit a scalar `BlackLevel`.**

### 3.3 What `photonforge` says it will additionally require

**[PF-PLAN]** `raw-format.md:453-454`:

> 1. Read `BlackLevel`, `WhiteLevel`, `CFAPattern`, `ColorMatrix1/2`, `AsShotNeutral`,
>    `NoiseProfile`, `NoiseReductionApplied`, `BitsPerSample` from *your own* iPhone 15 Pro DNGs at
>    several ISOs.

So the planned set is the reference's five **plus** `CFAPattern`, `ColorMatrix1`,
`NoiseReductionApplied`, `BitsPerSample`. Plus ISO, implied throughout the calibration plan
(`noise-calibration.md:291`: *"**read the actual ISO back from each DNG's metadata**"*).

### 3.4 `NoiseProfile` — recorded, never relied on

Both repos are explicit and agree. **[PF-PLAN]** `raw-format.md:268`: *"`NoiseProfile` is a
sanity-check reference, not a calibration source."* pf#22's resolution: *"Apple's model is a
factor-of-2 sanity band, never a substitute for calibration."* The RAWForge map inherits this
verbatim. **Contract item: emit it, do not depend on it.**

### 3.5 Measured values, all three sensors

Verified by me, `exiftool` over `C:\data\photonforge\datasets\{1x,0.5x,3x}.DNG` — all ISO 50, 1/125 s:

| Tag | 1x (wide) | 0.5x (ultra-wide) | 3x (tele) |
|---|---|---|---|
| `UniqueCameraModel` | `iPhone16,1 back camera` | `...back ultra wide camera` | `...back telephoto camera` |
| `CFAPattern` | **`[Blue,Green][Green,Red]`** (BGGR) | `[Red,Green][Green,Blue]` (RGGB) | `[Red,Green][Green,Blue]` (RGGB) |
| `ActiveArea` | `0 0 3024 4032` | **`0 96 3024 4128`** | `0 0 3024 4032` |
| `ImageWidth` | 4224 | 4224 | 4224 |
| `BlackLevel` / `WhiteLevel` | 528 / 4095 | 528 / 4095 | 528 / 4095 |
| `NoiseProfile` | `1.36463e-4, 2.57545e-7` | `2.4659e-4, 4.33623e-7` | `5.16539e-4, 1.30016e-6` |
| `DNGVersion` | 1.3.0.0 | **1.6.0.0** | 1.3.0.0 |
| `BaselineExposure` | *absent* | 0.005538 | 0.011055 |
| `NoiseReductionApplied` | `undef` | `undef` | `undef` |
| `ColorMatrix2` | distinct | distinct | distinct |

Three sensors, three CFA phases (two of them differing), three `ActiveArea`s, three colour matrices,
three noise profiles. This is pf#20's "three separate calibrations", confirmed at the tag level — and
it is the root of gaps **G1**, **G2** and **G7**.

---

## 4. Sub-question 3 — The join key

**Confirmed: the filename stem, and it is entirely load-bearing. [REF-IMPL] + [PF-PLAN]**

```python
# multinerf/internal/raw_utils.py:173-174
def load_raw_exif(image_name):
    base = os.path.join(image_dir, os.path.splitext(image_name)[0])
```

`os.path.splitext(...)[0]` strips the extension from the **COLMAP image name** and reuses the bare
stem to address both `<stem>.dng` and `<stem>.json`. The argument's docstring says exactly what the
names are:

```python
# multinerf/internal/raw_utils.py:287
    image_names: which images were successfully posed by COLMAP.
```

and those names come straight out of the COLMAP sparse model (`datasets.py:584-588`). So the chain is:

```
COLMAP sparse/0/images.bin  →  image name "IMG_5047.JPG"
                            →  stem "IMG_5047"
                            →  raw/IMG_5047.dng  +  raw/IMG_5047.json
```

`photonforge`'s research doc describes this and elects it, `pose-recovery.md:74-88`:

> The `multinerf` release keeps two parallel directories and joins them **by filename stem**: [...]
> **This filename-stem join is the whole mechanism of "pose transfer".** There is no clever
> registration step. Adopt the same convention in `photonforge`.

**Load-bearing, not incidental.** There is no fallback path, no manifest, no UUID, no checksum. A
stem collision silently pairs the wrong pose to the wrong RAW; a stem mismatch is a `FileNotFoundError`.
The RAWForge map's note that "filename-stem joining is the current mechanism" is **accurate**, and it
is the *only* mechanism.

**Contract item:** stems must be unique within a scene, stable between the proxy written to `images/`
and the DNG written to `raw/`, and must survive whatever transfer path gets the files off the phone.
`photonforge`'s shot list already guards the transfer: *"Transfer as **original DNG** — AirDrop or
Files copy. Never through Photos "optimised" export, Messages, or transcoding cloud sync. Keep
Halide's filenames."* (`shot-list.md:232`). **[PF-PLAN]**

---

## 5. Sub-question 4 — Bracket and station grouping

### 5.1 What the reference actually does: infers brackets from shutter values

There is no declared grouping. `exposure_idx` is **derived**, by bucketing distinct shutter speeds:

```python
# multinerf/internal/raw_utils.py:339-350
shutter_speeds = meta['ShutterSpeed']
# Sort the shutter speeds from slowest (largest) to fastest (smallest).
unique_shutters = np.sort(np.unique(shutter_speeds))[::-1]
exposure_idx = np.zeros_like(shutter_speeds, dtype=np.int32)
for i, shutter in enumerate(unique_shutters):
    exposure_idx[shutter_speeds == shutter] = i
meta['exposure_idx'] = exposure_idx
meta['unique_shutters'] = unique_shutters
meta['exposure_values'] = shutter_speeds / unique_shutters[0]
```

Three consequences that bind RAWForge:

1. **Exposure identity is by *value*, not by rung index.** Two frames land in the same bucket iff
   their parsed shutter floats are `==`. Apple quantises requested durations (the capture set shows
   `1/995`, `1/1010`, `1/1980`, `1/499` — none of them the round numbers requested), so a bracket
   ladder that *intends* six rungs can produce seven or five buckets if the device rounds
   inconsistently across stations. **RAWForge must log requested *and* achieved exposure.**
2. **ISO is invisible to bracketing.** Only shutter is bucketed. This is consistent with — and
   independently justifies — the RAWForge map's locked "vary shutter, not ISO" constraint, and with
   `raw-format.md:449`: *"Do not mix gain and time changes within one radiance bracket."*
3. **Nothing groups frames into a *stack*.** `exposure_idx` says "this frame is rung 3"; it never
   says "these six frames are one bracket at one pose".

### 5.2 Station grouping: the reference has none

`pose-recovery.md:510-512` states it plainly **[PF-PLAN]**:

> `transforms.json` has no notion of a bracket. Each entry in `frames` is
> `{file_path, transform_matrix, ...}` [...]; nothing stops several frames carrying byte-identical
> `transform_matrix` values.

The doc lays out three candidate representations (`pose-recovery.md:506-580`) and recommends (c):

> **(c) One pose per merged HDR image — recommended for `photonforge`.**
>
> ```
> station_0001/   raw/{ev-2,ev0,ev+2}.dng   →   merged/station_0001.exr   (linear HDR)
>                 proxy/station_0001.jpg    →   COLMAP  →  pose
> ```
>
> Then `transforms.json` (or the COLMAP model) has exactly **one frame per station** [...] This
> mirrors RawNeRF's filename-stem join (§1.2), just with the merged image standing in for the
> single DNG.

So the *planned* answer is: **station is a directory name; bracket is the set of DNGs inside that
directory's `raw/`; the join to pose happens at the station stem after an HDR merge.** All
**[PF-PLAN]**, none implemented, and structurally different from the flat `raw/` the reference reads.

### 5.3 The direct contradiction with RAWForge's own map

RAWForge's locked constraint says:

> **Bracket semantics** — All frames in a bracket share one station and one pose; the app must
> express that grouping, **not leave it to filename convention**. — pf#6

But pf#6's actual resolution *is* the filename convention, plus a directory name. **The map's
constraint and the research it cites point in opposite directions.** This is gap **G6** and it is the
single most consequential thing this ticket surfaces for RAWForge's design: the app is being asked to
emit an explicit grouping that the downstream consumer has no slot to read.

Also unresolved upstream: [pf#10](https://github.com/tangericm/photonforge/issues/10) (Scene capture
protocol, **OPEN**) names bracket strategy *"the central trade [...] it drives the reconstruction
design"*, and [pf#12](https://github.com/tangericm/photonforge/issues/12) (Reconstruction
architecture, **OPEN**) still owns *"Whether brackets are merged to HDR before training or fed as
individual exposures"*. Until pf#12 closes, whether the bracket even survives to the model is open.

---

## 6. Sub-question 5 — Sidecar / log input

**One sidecar is read. It is not a capture log. [REF-IMPL]**

```python
# multinerf/internal/raw_utils.py:177-178
    with utils.open_file(base + '.json', 'rb') as f:
      exif = json.load(f)[0]
```

Its provenance is documented in `process_exif`:

```python
# multinerf/internal/raw_utils.py:219-222
  Input should be a list of dictionaries loaded from JSON files.
  These JSON files are produced by running
    $ exiftool -json IMAGE.dng > IMAGE.json
  for each input raw file.
```

### Schema

**[MEASURED]** from the released RawNeRF scene at
`C:\data\photonforge\datasets\rawnerf\scenes\candle\raw\IMG_5047.json` — a 107-key exiftool dump:

```json
[{ "SourceFile": "IMG_5047.dng",
   "ShutterSpeed": "1/45",  "ExposureTime": "1/45",  "ISO": 2000,
   "BlackLevel": 528,       "WhiteLevel": 4095,
   "AsShotNeutral": "0.8357477784 1 0.3002712429",
   "ColorMatrix2": "0.8299484253 -0.2738865316 ... 0.5364223123",
   "NoiseProfile": "0.00016900780009 3.22310209e-06",
   "CFAPattern": "[Red,Green][Green,Blue]",
   "UniqueCameraModel": "iPhone10,6 back camera", ... }]
```

Structural requirements this imposes:

- Top level is a **one-element JSON array** (`json.load(f)[0]`), not an object.
- Numeric-vector tags are **space-separated strings**, not JSON arrays — the parser is
  `[float(z) for z in x[key].split(' ')]` (`raw_utils.py:247`). **Running `exiftool -n` would emit
  real numbers and break this path.** The sidecar must be exiftool's *default* (PrintConv) rendering.
- Scalars stay scalars (`raw_utils.py:243-245`).

### There is no capture-log schema, and no issue proposes one

I checked all 22 `photonforge` issues and all six docs. **No `photonforge` issue proposes a capture
log, manifest, or protocol sidecar.** The nearest thing is
[pf#13](https://github.com/tangericm/photonforge/issues/13) (Package and API surface, **OPEN**),
whose *"On-disk formats"* bullet is an unanswered question:

> **On-disk formats.** What a reconstructed scene is as a file, what a generated dataset looks like
> on disk, and whether the output is DNG, NPY, or something else.

What `photonforge` *does* have is human-prose "log this" instructions in its shooting protocols —
which is exactly the manual step RAWForge exists to automate:

- `shot-list.md:68`: *"**Log the shutter you locked for each segment.** The analysis cannot recover it otherwise."*
- `shot-list.md:234`: *"**Log the shutter you locked for each of blocks 2, 3 and 4.** The analysis needs it and it is not otherwise recoverable which sweep a given shutter belonged to."*
- `isp-smoothing-capture.md:72-76`: *"Log this — Shutter used for each block (the analysis cannot recover it) · Anything that moved, and between which frames · Roughly what the textured target was."*

**This is the strategic finding for RAWForge#3.** The map's headline promise is *"a machine-readable
capture log written beside the frames rather than reconstructed from EXIF later"*. `photonforge` has
demonstrated, repeatedly and in its own words, that it *needs* such a log — and has no reader for
one, no schema for one, and no ticket to design one. **RAWForge is currently specifying a producer
for a consumer that does not exist.** See gap **G5**.

---

## 7. Sub-question 6 — Multi-sensor handling

**No. Nothing distinguishes sensors, anywhere — implemented or planned. [REF-IMPL] absent, [PF-PLAN] absent**

Three pieces of evidence from the reference:

1. **Schema is decided from frame zero and applied to all:**
   ```python
   # multinerf/internal/raw_utils.py:236-239
   exif = exifs[0]
   # Convert from array of dicts (exifs) to dict of arrays (meta).
   for key in _EXIF_KEYS:
       exif_value = exif.get(key)
   ```
   If image 0 lacks a tag that image 1 has, the tag is dropped for the whole dataset.

2. **Colour transform is computed per image but *applied* from frame zero:**
   ```python
   # multinerf/internal/raw_utils.py:368-370
   cam2rgb0 = meta['cam2rgb'][0]
   meta['postprocess_fn'] = lambda z, x=exposure: postprocess_raw(z, cam2rgb0, x)
   ```

3. **COLMAP is invoked with a single shared camera:**
   `--ImageReader.single_camera 1` — `pose-recovery.md:97`, quoting multinerf's
   `scripts/local_colmap_and_resize.sh`. One intrinsics block for the entire scene.

Meanwhile `photonforge` has *established* that three calibrations are needed (pf#20, closed:
*"Per-sensor differences in CFA pattern, `ActiveArea` and `NoiseProfile` mean three separate
calibrations"*) and I confirmed all three differ at the tag level (§3.5). But **there is no planned
mechanism for selecting a calibration per frame.** `photonforge`'s map still lists as unspecified:

> **Whether v1 covers one sensor or three** — the telephoto's declared noise is ~3.8x the main
> sensor's and each needs its own dark frames and photon transfer curve.

`UniqueCameraModel` is the obvious discriminator, is present, and is distinct across all three
(§3.5) — but nothing reads it. **Contract item for RAWForge: emit `UniqueCameraModel` (and don't mix
sensors within one scene directory) — but note the selection mechanism itself is gap G7, and
RAWForge cannot close it by writing metadata.**

One thing that *does* simplify: pf#22 established **2x cannot be captured in RAW at all** — Process
Zero ignores the zoom and produces a byte-identical 1x frame. So it is three sensors, not four, and
RAWForge should refuse a 2x RAW capture rather than emit a mislabelled one.

---

## 8. Sub-question 7 — Directory layout expectations

### 8.1 What the reference reads — verified on disk

**[REF-IMPL]** `raw_utils.py:305` (`image_dir = os.path.join(data_dir, 'raw')`), `datasets.py:580`
(`colmap_dir = os.path.join(self.data_dir, 'sparse/0/')`), `datasets.py:617`.
**[MEASURED]** at `C:\data\photonforge\datasets\rawnerf\scenes\candle\`:

```
<scene>/
├── raw/                    # 346 entries = 173 DNGs + 173 JSONs, FLAT, interleaved
│   ├── IMG_5047.dng
│   ├── IMG_5047.json
│   ├── IMG_5048.dng
│   └── ...
├── images/                 # IMG_5047.JPG ...  (proxies COLMAP ran on)
├── sparse/0/               # cameras.bin, images.bin, points3D.bin, project.ini
├── poses_bounds.npy
├── database.db
└── colmap_output.txt
```

Notes that matter:

- `raw/` is **flat**. No per-station, per-bracket or per-sensor subdirectories.
- Extensions differ across directories (`.JPG` in `images/`, `.dng` in `raw/`) and that is fine —
  only the stem is used.
- An optional `hdrplus_test/merged.dng` switches the loader into "test scene" mode, in which `raw/`
  is expected to contain `train/` and `test/` **subdirectories** (`raw_utils.py:307-313`). RAWForge
  should **not** create that file or those subdirs unless it means to trigger that mode.
- Raw mode forces full resolution — downsampling is skipped *"because of the Bayer mosaic pattern"*
  (`datasets.py:571-573`).

### 8.2 What `photonforge` plans instead

**[PF-PLAN]** `pose-recovery.md:566-568` — per-station directories with `raw/`, `merged/`, `proxy/`
(quoted in §5.2). **[PF-PLAN]** its calibration shoots use a flat block-per-directory shape,
`shot-list.md:225-230`:

```
C:\data\photonforge\captures\issue22\
    block0_content\  block1_repeat\  block2_main\
    block3_ultrawide\  block4_tele\  block5_2x\
    block6_shutter\  block7_dark\
```

and `isp-smoothing-capture.md:84` names frames by block: `A1-1.DNG … A1-10.DNG`, `D1-1.DNG …`.

So there are **three** different layouts in play — the reference's flat `raw/`, the planned
per-station tree, and the calibration block tree — and no ticket reconciles them. Gap **G8**.

---

## 9. Gaps — where the contract is underspecified

Ordered by how much they should change RAWForge's design.

### G5 (highest) — No capture-log consumer exists, and no ticket owns one

`photonforge` reads exactly one sidecar: an exiftool dump of the DNG's own tags. It has no reader,
no schema, and no open issue for an independent capture log — while its own protocols repeatedly
instruct a human to *"log the shutter [...] the analysis cannot recover it"*
(`shot-list.md:68`, `:234`; `isp-smoothing-capture.md:72-76`).

RAWForge's entire justification for existing over Halide is *"the capture log written beside the
frames rather than reconstructed from EXIF later"*. **The map cannot lock "output contract = whatever
photonforge ingest reads" and also promise a capture log, because photonforge ingest reads no log.**
One of the two has to move. The cleanest resolution: RAWForge specifies the log schema *and* the
map spawns a `photonforge` ticket to consume it — the contract flows both ways, or the log is
write-only. **This should probably become a new sub-issue on RAWForge#1.**

### G6 — "Express the grouping" contradicts the only grouping mechanism specified

The map locks *"the app must express that grouping, not leave it to filename convention"* and cites
pf#6 — but pf#6's resolution **is** the filename convention plus a directory name
(`pose-recovery.md:88`, `:566-568`), and the reference loader derives bracket membership by bucketing
shutter *values* (`raw_utils.py:339-348`), with no notion of a station at all. RAWForge needs to
decide whether it emits (a) a directory-per-station tree, (b) an explicit grouping field in a
sidecar that nothing reads yet, or (c) both. Blocked-ish on pf#10 and pf#12, both **OPEN**.

### G3 — The shutter-speed parser breaks at exposures ≥ 0.25 s, colliding with the locked 1 s ceiling

```python
# multinerf/internal/raw_utils.py:250-252
meta['ShutterSpeed'] = np.fromiter(
    (1. / float(exif['ShutterSpeed'].split('/')[1]) for exif in exifs), float)
```

This requires the string to literally contain `/`. exiftool's rendering rule (primary source, its own
Perl, `C:\data\photonforge\tools\exiftool\perl-distro\lib\Image\ExifTool\Exif.pm:5701-5711`):

```perl
sub PrintExposureTime($)
{
    my $secs = shift;
    return $secs unless Image::ExifTool::IsFloat($secs);
    if ($secs < 0.25001 and $secs > 0) {
        return sprintf("1/%d",int(0.5 + 1/$secs));
    }
    $_ = sprintf("%.1f",$secs);
    s/\.0$//;
    return $_;
}
```

So **any exposure at or slower than ~1/4 s renders as a decimal** (`"0.5"`, `"1"`, `"2"`) and
`split('/')[1]` raises `IndexError`. RAWForge's map locks a **1 s exposure ceiling**, and
`photonforge`'s own shot list plans 1/2 s and 1/8 s frames (`shot-list.md:185-187`) — both squarely
in the broken region. Every frame in the existing capture set happens to be faster than 1/4 s
(measured distinct values: `1/125, 1/250, 1/499, 1/995, 1/1010, 1/1980`), which is why this has never
fired.

Secondary defect: the parser **discards the numerator**, so a hypothetical `"2/5"` silently parses as
`1/5`. And the obvious workaround — generating the sidecar with `exiftool -n` — breaks the
space-separated-string parsing of every vector tag (§6). This cannot be fixed from RAWForge's side by
emitting different metadata; it is a downstream patch. **RAWForge should record exposure in its own
log as a robust numeric value (and note this collision in the spec) rather than assume EXIF round-trips.**

### G1 — CFA phase is hardcoded RGGB; the main camera is BGGR

The reference assumes a fixed mosaic phase in two places:

```python
# multinerf/internal/raw_utils.py:84-88 (bilinear_demosaic docstring)
  Input data should be ndarray of shape [height, width] with 2x2 mosaic pattern:
    |red  |green|
    |green|blue |

# multinerf/internal/raw_utils.py:70-71 (pixels_to_bayer_mask)
  # Red is top left (0, 0).
  r = (pix_x % 2 == 0) * (pix_y % 2 == 0)
```

`CFAPattern` is not in `_EXIF_KEYS` and is never read. **[MEASURED]** the iPhone 15 Pro **1x main
camera is BGGR** (`[Blue,Green][Green,Red]`, `CFAPattern2 "2 1 1 0"`) while 0.5x and 3x are RGGB.
RawNeRF's iPhone X was RGGB, which is why this never surfaced. The primary sensor would demosaic
with red and blue swapped, and `pixels_to_bayer_mask` — which drives the per-pixel training loss
weights — would be wrong on every pixel.

RAWForge cannot fix this by emitting metadata; it can only make it *fixable*. **Contract item: always
emit `CFAPattern`/`CFAPattern2`, and never let the spec assume a shared phase across sensors.**

### G2 — `ActiveArea` is never applied, and this device has padding

`rawpy.imread(f).raw_image` (`raw_utils.py:176`) is the **uncropped** sensor array; LibRaw's cropped
accessor `.raw_image_visible` is not used, and `ActiveArea`/`DefaultCropOrigin` are not read.
**[MEASURED]** the iPhone 15 Pro reports `ImageWidth 4224` against `ActiveArea 0 0 3024 4032` —
**192 padding columns** — and the ultra-wide's active region starts at **column 96**
(`ActiveArea 0 96 3024 4128`), a different origin from the other two. pf#20's Block 0 note confirms:
*"`ActiveArea 0 0 3024 4032` against `ImageWidth 4224` confirms the 192 columns of tile padding on
this device."* RawNeRF's iPhone X had `ImageWidth 4032` — no padding — which is again why this is
latent. Ingesting unmodified would feed 192 columns of garbage into the reconstruction and shift the
ultra-wide's crop.

### G7 — Per-frame calibration selection has no mechanism

pf#20 established three sensors need three calibrations; §3.5 confirms three distinct CFA patterns,
`ActiveArea`s, colour matrices and noise profiles. But the reference decides schema from `exifs[0]`
(`raw_utils.py:236`), postprocesses with `cam2rgb[0]` (`:369`), and runs COLMAP `--single_camera 1`.
No planned design selects a calibration per frame. `UniqueCameraModel` is the natural key and is
present and distinct — nothing reads it. `photonforge`'s map still lists *"Whether v1 covers one
sensor or three"* as unspecified.

### G8 — Three incompatible directory layouts, none authoritative

Flat `raw/` (reference, §8.1) vs. per-station tree (`pose-recovery.md:566-568`) vs. block-per-
directory calibration shape (`shot-list.md:225-230`). pf#13's *"On-disk formats"* bullet is **OPEN**
and is the ticket that would settle it. RAWForge should not hard-code a layout until pf#13 resolves,
or should emit the flat form (the only one with a reader) and treat the station tree as a view.

### G4 — `BlackLevel` must be scalar, which conflicts with per-CFA-plane calibration ambitions

`reshape(-1,1,1)` (`raw_utils.py:355`) assumes one value per image. The device currently emits a
scalar `528`, so this is fine **today** — but `photonforge`'s noise model is explicitly per-CFA-plane
(`noise-calibration.md:11`) and it plans to *"Store a **per-ISO measured black level**, not the tag
value"* (`noise-calibration.md:397`). If RAWForge ever writes its own DNGs with a 4-vector
`BlackLevel`, ingest breaks. **Contract item: scalar `BlackLevel`.**

### G9 (minor) — Case sensitivity and file discovery

The glob is `'*.dng'` lowercase (`raw_utils.py:184`) and the open is `base + '.dng'`
(`raw_utils.py:175`), while iOS writes `.DNG` and the shot list says to keep the phone's filenames.
Harmless on Windows, a silent empty dataset on Linux. **Contract item: normalise to lowercase `.dng`
on export.**

### G10 (minor) — `DNGVersion` is not uniform across sensors

**[MEASURED]** `1.3.0.0` on 1x/3x, `1.6.0.0` on 0.5x, same phone and session. Nothing reads it, so it
is inert today — but it means RAWForge cannot promise a single container version across sensors, and
any future validation gate on `DNGVersion` would reject the ultra-wide or the other two.

---

## 10. Summary table — implemented vs planned

| Contract element | Status | Pointer |
|---|---|---|
| Any `photonforge` ingest code | **does not exist** | `git ls-tree origin/main`, `language: null` |
| `.dng` + sibling `<stem>.json` exiftool dump | **[REF-IMPL]** | `raw_utils.py:175-178` |
| `rawpy`/LibRaw loader, `.raw_image` (uncropped) | **[REF-IMPL]** | `raw_utils.py:176` |
| Required tags: `BlackLevel`, `WhiteLevel`, `AsShotNeutral`, `ColorMatrix2` | **[REF-IMPL]** | `raw_utils.py:200-206, 355-356, 257, 261` |
| `NoiseProfile` read, optional, diagnostic only | **[REF-IMPL]** + **[PF-PLAN]** | `raw_utils.py:205`; `raw-format.md:268`; pf#22 |
| `ShutterSpeed` as literal `1/N` string | **[REF-IMPL]** (fragile, **G3**) | `raw_utils.py:250-252` |
| Filename-stem join, COLMAP names → DNG | **[REF-IMPL]** + **[PF-PLAN]** | `raw_utils.py:174, 287`; `pose-recovery.md:88` |
| Bracket = frames sharing a shutter *value* | **[REF-IMPL]** | `raw_utils.py:339-348` |
| Station grouping by directory, one pose per station | **[PF-PLAN]** only | `pose-recovery.md:566-571` |
| Flat `raw/` + `images/` + `sparse/0/` layout | **[REF-IMPL]** + **[MEASURED]** | `raw_utils.py:305`, `datasets.py:580`; RawNeRF release on disk |
| Per-station `raw/`+`merged/`+`proxy/` layout | **[PF-PLAN]** only | `pose-recovery.md:566-568` |
| Reads `CFAPattern`, `ActiveArea`, `ISO`, `ColorMatrix1`, `BitsPerSample` | **[PF-PLAN]** only | `raw-format.md:453-454` |
| Any capture log / manifest reader | **neither** — no code, no schema, no issue | pf#13 **OPEN** |
| Per-sensor calibration selection | **neither** | pf#20 states the need; nothing implements or plans it |
| ProRAW disqualified (`NoiseReductionApplied`) | **[PF-PLAN]** + **[MEASURED]** | pf#2; measured `undef` on all three |
| Three sensors → three CFA/ActiveArea/matrices | **[MEASURED]** | §3.5, this document |
