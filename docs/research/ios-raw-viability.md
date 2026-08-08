# Viability gate: deterministic undemosaiced Bayer RAW from public iOS API

Research for [RAWForge#2](https://github.com/tangericm/RAWForge/issues/2). Target device: iPhone 15 Pro.
Platform baseline: iOS 26 shipping (2026-08); iOS 27 announced at WWDC26.

## Source tiers

Every claim below carries a URL. Sources are tiered, and the tier is stated inline where it matters.

- **P1 — Apple developer documentation.** `developer.apple.com/documentation/...`. Note: those pages are
  JS-rendered and return nothing to a plain fetch; the content was read from Apple's own DocC JSON backing
  store at `developer.apple.com/tutorials/data/documentation/<path>.json`, which is what the site renders.
- **P1 — Apple WWDC session transcripts.** `developer.apple.com/videos/play/...`.
- **P1-mirror — Apple SDK headers.** `AVCapturePhotoOutput.h` and `AVCaptureDevice.h` from `iPhoneOS26.5.sdk`.
  The *text* is Apple's and is materially richer than the published docs — several load-bearing rules exist
  **only** in the headers. The *transport* was a third-party SDK mirror
  (`raw.githubusercontent.com/xybp888/iOS-SDKs`), so verify against local Xcode before shipping code on it.
- **P2 — Apple support.apple.com / Apple Developer Forums staff replies.** Apple-attributable, not developer
  documentation.
- **C — Corroboration only.** Lux/Halide, third-party issue trackers. Labelled at every use.
- **Project-measured.** Facts established on the target device by `photonforge` research, inherited via the
  [RAWForge map](https://github.com/tangericm/RAWForge/issues/1). Not Apple claims.

---

## Verdict

**Yes — protocol-grade deterministic Bayer capture is achievable from public, un-entitled iOS API on
iPhone 15 Pro, and the API is structurally *more* favourable than expected.** Nothing here blocks the app.

The reason it works is a convergence that is easy to miss: **Apple's Bayer RAW capture rules force the
capture into exactly the deterministic regime this project needs.** Requesting a Bayer RAW pixel format
makes `photoQualityPrioritization = .speed` mandatory and `videoZoomFactor = 1.0` mandatory, and those two
constraints are, independently, the documented preconditions for (a) `setExposureModeCustom` duration/ISO
actually being honoured rather than overridden by multi-image fusion, and (b) no sensor cropping. You do
not have to fight the pipeline into determinism — asking for Bayer *is* the request for determinism.

Four load-bearing structural facts:

1. **Bayer RAW is only offered on single-camera `AVCaptureDevice`s** (WWDC21, P1). Virtual devices
   (`builtInTripleCamera`) get ProRAW, not Bayer. So the auto-switching problem does not need to be
   *solved* — it is excluded by the format choice. You open the physical device, and there is nothing to
   switch to.
2. **Manual/custom exposure and bracketed capture each independently disqualify zero-shutter-lag**
   (header + WWDC23, P1). The ring-buffer time-travel path cannot silently apply to this app's captures.
3. **`AVCapturePhotoBracketSettings` supports RAW *and* manual exposure brackets** — a documented
   initializer taking a `rawPixelFormatType` plus an array of
   `AVCaptureManualExposureBracketedStillImageSettings`. No sequential-capture fallback is needed.
4. **RAW photo captures never have geometric distortion correction applied**, regardless of the device
   setting (`AVCaptureDevice.h`, P1-mirror). Important for the ultra-wide.

### What fails, or is unproven

| Risk | Severity | Status |
|---|---|---|
| **Bayer availability on ultra-wide is not documented by Apple.** WWDC21 names "wide and tele" as examples of single-camera devices; ultra-wide is never named. | Low — project has already measured all three emitting genuine Bayer | Undocumented; project-measured yes |
| **White balance → DNG. Nothing documented.** Apple never states whether locked gains reach `AsShotNeutral`, whether they are re-metered at capture, or whether gains touch the Bayer pixels at all. | **High — this is the single biggest unknown in the ticket** | Fully undocumented; must be measured |
| **Local tone mapping still adapts under locked exposure.** Apple staff forum reply (P2), not documentation. Mitigation (`isGlobalToneMappingEnabled`) "will still adapt slightly", per the same reply. | Medium | Apple-attributable but not documented; effect on *Bayer* path unstated |
| **No documented per-frame correction spec for Bayer DNG** — lens shading, black level, PDAF pixel repair, which DNG opcodes Apple writes. | Medium — calibration must not assume | Fully undocumented |
| **`maxBracketedCapturePhotoCount` may be 0.** Apple: "Some formats do not support bracketed capture at all." No per-device values published. | Medium — gates the whole bracket design | Undocumented; must be probed |
| **48 MP RAW is not exposed by iOS.** | Confirmed constraint, not a surprise | Corroborated (Lux, C) + project-measured |
| **DocC and the SDK header disagree** on which superclass settings a bracket supports. The header is newer and narrower; DocC's list predates iOS 13. | Low, but resolve by trusting the header | Documentation conflict, resolved below |

---

## Per-sensor capability table

`AVCaptureDevice.DeviceType` values, each opened **directly as a physical device** via
`AVCaptureDeviceDiscoverySession` — never via `builtInTripleCamera`.

| Sensor | DeviceType (iOS avail.) | Bayer RAW pixel format offered | Custom exposure | Locked WB w/ custom gains | Sensor-switch risk | Manual-exposure RAW bracket | Min iOS |
|---|---|---|---|---|---|---|---|
| **Wide (1x, 24 mm)** | `.builtInWideAngleCamera` (iOS 10.0+) | One of `kCVPixelFormatType_14Bayer_{RGGB,GRBG,BGGR,GBRG}`. **Apple documents no per-device format mapping** — read `availableRawPhotoPixelFormatTypes` at runtime. WWDC21 names "wide" explicitly as a Bayer-capable single-camera device. | Yes — `.custom` documented; not excluded for single-camera devices | Yes, gated on `isLockingWhiteBalanceWithCustomDeviceGainsSupported` | **None documented.** `constituentDevices` empty, `activePrimaryConstituent` nil, `minAvailableVideoZoomFactor` == 1.0 | Yes — documented init; count gated by `maxBracketedCapturePhotoCount` | 11.0 (17.0 recommended) |
| **Ultra-wide (0.5x, 13 mm)** | `.builtInUltraWideCamera` (iOS 13.0+) — *"may only be discovered using an AVCaptureDeviceDiscoverySession"* | **Undocumented by Apple.** Never named in the WWDC21 Bayer statement. Project-measured: emits genuine Bayer with its own CFA pattern. Probe at runtime. | Same as wide | Same as wide | Same as wide | Same as wide | 13.0 (17.0 recommended) |
| **Telephoto (3x, 77 mm)** | `.builtInTelephotoCamera` (iOS 10.0+) — discovery-session only | Same as wide; WWDC21 names "tele" explicitly | Same as wide | Same as wide | Same as wide | Same as wide | 11.0 (17.0 recommended) |
| **2x (main-sensor crop)** | — no device type — | **Structurally unreachable in Bayer RAW.** The header rule requires `videoZoomFactor == 1.0` for any Bayer RAW capture. A 2x crop is a zoom on the wide sensor, so it is excluded by the capture rules themselves, not merely by hardware. Confirms the map's locked constraint from the API side. | n/a | n/a | n/a | n/a | n/a |
| **`.builtInTripleCamera` (for contrast)** | iOS 13.0+ | ProRAW only per WWDC21 — **disqualified** | **Not supported.** Header: *"A device of this device type does not support … AVCaptureExposureModeCustom and manual exposure bracketing."* | **Not supported** — same header list | Auto-switches by design | No | — |

Constraints that apply identically to all three usable rows, from `AVCapturePhotoOutput.h`
(`-capturePhotoWithSettings:delegate:`, P1-mirror) — violation throws `NSInvalidArgumentException`:

- `photoQualityPrioritization` **must** be `.speed`
- `videoZoomFactor` **and** the connection's `videoScaleAndCropFactor` **must both** be `1.0`
- `constantColorEnabled` **must** be `NO`
- delegate must implement the RAW callback
- 12 MP only — 48 MP raw sensor data is not exposed by iOS

---

## Sub-question 1 — Bayer RAW availability per sensor

### What `availableRawPhotoPixelFormatTypes` returns

`@nonobjc var availableRawPhotoPixelFormatTypes: [OSType] { get }` — iOS 10.0+. Note the Swift element type
is `OSType`, not `NSNumber`.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotopixelformattypes-9t9k5)

Verbatim discussion:

> "To capture a photo in RAW format, use the `init(rawPixelFormatType:)` or
> `init(rawPixelFormatType:processedFormat:)` initializer to create your photo settings object. The value
> for that initializer's `rawPixelFormatType` parameter must be one of the Bayer RAW format identifiers
> listed in this array."
>
> "Read this property only after adding the photo capture output to an `AVCaptureSession` object containing
> a video source. If the photo capture output isn't connected to a session with a video source, this array
> is empty."
>
> "Not all devices support RAW image capture. If the current device doesn't support RAW capture, this array
> is empty."

Those are the **only two documented emptiness conditions**. Apple's *current* reference docs state **no**
session-preset or `activeFormat` dependency for the RAW array. The only Apple statement of a preset
requirement is from 2016 and has never been restated:

> "RAW is only supported when using the photo format, the preset photo, same as Live Photo. It's only
> supported on the rear camera."
> — [WWDC16 session 501, P1](https://developer.apple.com/videos/play/wwdc2016/501/)

**Whether the `.photo` preset requirement still holds in iOS 26 is undocumented.** Set
`sessionPreset = .photo` anyway; it costs nothing and it is also the documented route to
`isHighestPhotoQualitySupported` formats.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/ishighestphotoqualitysupported)

### Ordering

Apple documents ordering in exactly one place, and only between the two RAW families — see sub-question 2.
**There is no documented ordering among Bayer formats themselves.** Do not index; filter.

### The Core Video Bayer constants

All four exist as public symbols. Apple's DocC pages for them have **no abstract and no discussion** — only
a declaration — and publish no four-character codes.

- [`kCVPixelFormatType_14Bayer_RGGB`](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_rggb)
- [`kCVPixelFormatType_14Bayer_GRBG`](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_grbg)
- [`kCVPixelFormatType_14Bayer_BGGR`](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_bggr)
- [`kCVPixelFormatType_14Bayer_GBRG`](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_gbrg)

The per-constant availability shown on those pages (iOS 4.0+) is the **enclosing enum's** availability and
is meaningless for these constants. Treat per-constant availability as undocumented.

Codes and semantics come from `CVPixelBuffer.h` (`iPhoneOS26.5.sdk`, P1-mirror):

```c
kCVPixelFormatType_64RGBALE     = 'l64r',  /* 64 bit RGBA, 16-bit little-endian full-range (0-65535) */
kCVPixelFormatType_14Bayer_GRBG = 'grb4',  /* Bayer 14-bit LE, packed in 16 bits, G R G R… / B G B G… */
kCVPixelFormatType_14Bayer_RGGB = 'rgg4',  /* Bayer 14-bit LE, packed in 16 bits, R G R G… / G B G B… */
kCVPixelFormatType_14Bayer_BGGR = 'bgg4',  /* Bayer 14-bit LE, packed in 16 bits, B G B G… / G R G R… */
kCVPixelFormatType_14Bayer_GBRG = 'gbr4',  /* Bayer 14-bit LE, packed in 16 bits, G B G B… / R G R G… */
```

Corroborated by WWDC16/501 (P1): *"We've added four new constants to CVPixelBuffer.h to describe the four
different Bayer patterns that you'll encounter on our cameras… Basically they describe the order of the
reds, greens and blues in the checkerboard."* Same session, on bit depth: *"It's a 10-bit sensor RAW
packaged in 14 bits per pixel instead of eight."* — **2016-era statement; the actual bit depth on iPhone 15
Pro is undocumented.**

Note the Core Video listing page's caveat: *"Core Video does not provide support for all of these formats;
this list defines only their names."*
[P1](https://developer.apple.com/documentation/corevideo/1563591-pixel_format_identifiers)

`kCVPixelFormatType_64RGBALE` is **never documented by Apple as the ProRAW format.** The link is
inferential: WWDC21 says *"An example of a ProRAW pixel format is l64r, that's a 16-bit full range RGBA
pixel format"*, and `'l64r'` is that constant. Apple says "*an* example", not "the format" — never hardcode
it; use `isAppleProRAWPixelFormat(_:)`.

Unrelated and easy to confuse: `kCVPixelFormatType_16VersatileBayer` (`'bp16'`),
`kCVPixelFormatType_96VersatileBayerPacked12`, `kCVPixelFormatType_64RGBA_DownscaledProResRAW` — these are
ProRes RAW *video* decode formats, not `AVCapturePhotoOutput` still formats.

### Per-sensor availability — what Apple actually documents

**Apple's reference documentation documents nothing.** The device-type pages for
[`builtInUltraWideCamera`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinultrawidecamera)
and
[`builtInTelephotoCamera`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintelephotocamera)
make no mention of RAW, and there is no per-`AVCaptureDevice.Format` RAW-capability property anywhere in
the API.

The only Apple statement on per-device Bayer availability is verbal, from
[WWDC21 session 10160 (P1)](https://developer.apple.com/videos/play/wwdc2021/10160/):

> "While Bayer RAW is only supported on single-camera AVCaptureDevices, like wide and tele. Apple ProRAW is
> supported on all devices, including dual wide-, dual-, and triple-camera devices that seamlessly switch
> between cameras when zooming."

> "Bayer RAW was introduced in iOS 10 and is supported on a wide range of devices. Apple ProRAW was
> introduced in iOS 14.3 and is supported on iPhone 12 Pro and iPhone 12 Pro Max."

This is the single most useful sentence for this project. It says the *physical/virtual* distinction is
what gates Bayer, not the individual lens. Ultra-wide is a single-camera device, so it should qualify —
but Apple never names it, the statement is from the iPhone 12 Pro era and predates the 48 MP quad-pixel
sensors, and it has not been restated since. **Treat ultra-wide Bayer as undocumented-but-expected and
probe `availableRawPhotoPixelFormatTypes` per device at runtime.** The project has already measured all
three rear sensors emitting genuine Bayer with distinct CFA patterns
([map](https://github.com/tangericm/RAWForge/issues/1), project-measured).

Corroboration (C, Lux/Halide — the *Process Zero Manual*): Process Zero produces *"regular bayer, or
'native' raw files"*, and *"We sadly cannot take 48 megapixel Process Zero photos due to system
limitations… Both of these limitations are because we do not get 48 raw sensor data from iOS. We've filed a
request with Apple for this."* Same page confirms *"on iPhone 14 Pro and 15/15 Pro, it does not have a '2×'
lens."* — consistent with the API-side zoom rule.
<https://www.lux.camera/process-zero-manual/>

### Related format APIs

- `availableRawPhotoFileTypes: [AVFileType]` — iOS 11.0+. *"The list of file types currently supported for
  RAW format capture and output."* Header adds: *"If you've not yet added your receiver to an
  AVCaptureSession with a video source, no file types are available."*
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotofiletypes)
- `supportedRawPhotoPixelFormatTypes(for:) -> [OSType]` — iOS 11.0+. *"Returns the list of Bayer RAW pixel
  formats supported for photo data in the specified file type."*
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/supportedrawphotopixelformattypes(for:))
- `availableRawPhotoCodecTypes` and `supportedRawPhotoCodecTypes(forRawPhotoPixelFormatType:fileType:)` —
  **iOS 18.0+**, plus `AVCapturePhotoSettings.rawFileFormat` (iOS 18.0+), whose only documented key is
  `AVVideoAppleProRAWBitDepthKey` — i.e. ProRAW-oriented.

**Signature correction.** There is no
`AVCapturePhotoSettings(rawPixelFormatType:processedFormat:rawFileType:processedFileType:)`. The real
initializer is, iOS 11.0+:

```swift
convenience init(rawPixelFormatType: OSType, rawFileType: AVFileType?,
                 processedFormat: [String : Any]?, processedFileType: AVFileType?)
```

with `rawPixelFormatType` documented as *"The Bayer RAW pixel format type to use for capture."*
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/init(rawpixelformattype:rawfiletype:processedformat:processedfiletype:))
For RAW-only capture use `init(rawPixelFormatType:)` (iOS 10.0+).

---

## Sub-question 2 — Suppressing ProRAW

### How the two are distinguished

Only by two class predicates, both **iOS 14.3+**:

```swift
class func isBayerRAWPixelFormat(_ pixelFormat: OSType) -> Bool
class func isAppleProRAWPixelFormat(_ pixelFormat: OSType) -> Bool
```

[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isbayerrawpixelformat(_:)) ·
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawpixelformat(_:))

There is no enum, no bit flag, and no naming convention Apple commits to. Both are pure class functions over
an `OSType` — they classify a constant, they do not query device capability.

### Enabling ProRAW is strictly additive — the key sentence

From `AVCapturePhotoOutput.h`, `appleProRAWEnabled` discussion (`iPhoneOS26.5.sdk`, P1-mirror). **This
sentence does not appear in the published documentation:**

> "Setting this property to YES will enable support for taking photos in Apple ProRAW pixel formats. **These
> formats will be added to -availableRawPhotoPixelFormatTypes after any existing Bayer RAW formats.**
> Compared to photos taken with a Bayer RAW format, these photos will be demosaiced and partially processed.
> They are still scene-referred, and allow capturing RAW photos in modes where there is no traditional
> sensor/Bayer RAW available. Examples are any modes that rely on fusion of multiple captures. … When
> writing an Apple ProRAW buffer to a DNG file, the resulting file is known as 'Linear DNG'."

The header abstract is likewise sharper than DocC: *"Indicates whether the photo output is configured for
delivery of Apple ProRAW pixel formats **as well as** Bayer RAW formats."*

Published corroboration (P1): *"Enabling use of the Apple ProRAW format **adds an entry** to the photo
output's `availableRawPhotoPixelFormatTypes` array."*
<https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats>

So:

- `isAppleProRAWEnabled == false` → Bayer formats only (if any).
- `isAppleProRAWEnabled == true` → the same Bayer entries, **plus** ProRAW entries appended **after** them.
- Enabling ProRAW **never removes or replaces** Bayer entries. This is Apple's only documented ordering
  guarantee anywhere in the RAW API.

The word *existing* is load-bearing: if the selected device has no Bayer to begin with (a virtual device),
enabling ProRAW gives ProRAW-only. That is a device-selection problem, not a ProRAW problem.

### Can plain Bayer be requested unconditionally?

**Yes, and the simplest suppression is to do nothing.** `isAppleProRAWEnabled` is an opt-in `BOOL` property
defaulting to `NO` — DocC describes it as *"whether **you've configured** the photo output to deliver Apple
ProRAW formats"*. Never set it, and the array contains Bayer only.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawenabled)

Belt and braces: filter with `isBayerRAWPixelFormat` unconditionally, ignoring `isAppleProRAWEnabled`.
Apple's own sample does the opposite (prefers ProRAW when enabled) — invert it.

### What ProRAW actually does to the data — why it is disqualified

From `isAppleProRAWEnabled` (P1), verbatim:

> "Compared to photos taken in Bayer RAW format, the system **demosaics and partially processes** Apple
> ProRAW photos."

From WWDC21/10160 (P1):

> "The pixels in the DNG are scene-referred and linearizable, may be generated from multiple demosaiced
> exposures combined with image fusion, losslessly compressed 12-bit RGB; but we create these bits through
> an adaptive companding curve so we can achieve up to 14 stops of dynamic range."

> "Apple ProRAW allows photo-quality prioritization to be set to .balanced and .quality, which allows you to
> get the benefit of Apple image fusion to your RAW captures."

That last sentence is the inverse of what this project needs, and it is precisely why the Bayer path is the
right one: ProRAW exists to *let fusion in*. Confirms the map's `NoiseReductionApplied = 0.95` finding from
the API side.

### Does the system Settings ProRAW toggle affect a third-party app?

**Undocumented — in both directions. This is the clearest documentation gap in the whole ticket.**

Greps of `AVCapturePhotoOutput.h` (2,470 lines) and `AVCaptureDevice.h` (3,944 lines) for "Settings app",
"Camera app", "user preference", "third party" return zero relevant hits. No DocC page and no WWDC session
mentions a user-facing ProRAW toggle in the context of `AVCapturePhotoOutput`.

The toggle is documented only on support.apple.com (P2), and purely as a system-Camera feature:

> "To take photos with ProRAW, go to Settings > Camera > Formats, then turn on Apple ProRAW & Resolution
> Control under Photo Capture."
> "Only photos that you take with the main camera at 1x can be saved 48 MP. Ultra Wide, Telephoto, Night
> mode, flash, and macro photos can only be saved at 12 MP."
> <https://support.apple.com/en-us/119916>

Neither page says anything about third-party capture behaviour. The API shape — a settable, per-output,
defaulted-`NO` property — *suggests* independence, but that is a reading, not an Apple statement. **Test on
device with the toggle in both states, logging `isAppleProRAWSupported` and the full format array.**

### WWDC sessions

- **There is no WWDC20 "Discover Apple ProRAW" session.** ProRAW shipped in iOS 14.3 (December 2020), six
  months after WWDC20. Any reference to such a session is spurious.
- The developer session is **WWDC21 session 10160, "Capture and process ProRAW images"**.
- WWDC26 session 304 restates the taxonomy but adds nothing RAW-specific:
  > "Third, Bayer RAW photos. RAW gives you minimally processed data straight from the sensor. This is ideal
  > for post-processing and editing use cases. And fourth, Apple's ProRAW."
  <https://developer.apple.com/videos/play/wwdc2026/304/>

One asymmetry worth recording, from WWDC21 (P1): *"Live Photo capture is only supported with Bayer RAW but
portrait effects matte and semantic segmentation skin and sky mattes are only supported with ProRAW."* —
i.e. the semantic-rendering surface is a ProRAW feature and is structurally absent from the Bayer path.

---

## Sub-question 3 — Sensor selection determinism

### The virtual device is not merely undesirable — it is unusable for this app

`AVCaptureDevice.h` on `AVCaptureDeviceTypeBuiltInTripleCamera` (P1-mirror; identical text is published on
the [DocC page](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintriplecamera)):

> "A device of this device type does not support the following features:
> - **AVCaptureExposureModeCustom and manual exposure bracketing.**
> - Locking focus with a lens position other than AVCaptureLensPositionCurrent.
> - Locking auto white balance with device white balance gains other than AVCaptureWhiteBalanceGainsCurrent.
>
> Even when locked, exposure duration, ISO, aperture, white balance gains, or lens position may change when
> the device switches from one camera to the other."

The same three exclusions appear verbatim on `builtInDualCamera` (iOS 10.2+) and `builtInDualWideCamera`
(iOS 13.0+). Combined with the WWDC21 statement that Bayer is single-camera-only, **the virtual devices are
excluded twice over**: no Bayer, and no custom exposure or manual brackets.

### Opening the physical devices directly — the documented path

Each physical camera is a first-class `DeviceType` retrievable through `AVCaptureDeviceDiscoverySession`:

- `builtInWideAngleCamera` — iOS 10.0+
- `builtInUltraWideCamera` — iOS 13.0+ — *"may only be discovered using an AVCaptureDeviceDiscoverySession"*
- `builtInTelephotoCamera` — iOS 10.0+ — same restriction

[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession/init(devicetypes:mediatype:position:))

When you do, the switching machinery reports itself as absent:

- `constituentDevices` — *"The value of this property is an empty array when called on a device whose
  `isVirtualDevice` property is `false`."*
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/constituentdevices)
- `activePrimaryConstituent` — *"The value is `nil` for nonvirtual devices."* (Note: the Swift symbol is
  `activePrimaryConstituent`, **not** `activePrimaryConstituentDevice`.)
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeprimaryconstituent)
- `minAvailableVideoZoomFactor` — always `1.0` on single-camera devices
- `virtualDeviceSwitchOverVideoZoomFactors` — *"an empty array for nonvirtual devices"*

**Undocumented:** whether the `AVCaptureDevice` instances *inside* `constituentDevices` may themselves be
wrapped in a standalone `AVCaptureDeviceInput`. Do not rely on it. The documented path is a separate
`DiscoverySession` lookup by physical device type — which is what the app should do anyway.

### The switching-behavior API (iOS 15.0+) — present, but not needed here

`primaryConstituentDeviceSwitchingBehavior`, `setPrimaryConstituentDeviceSwitchingBehavior(_:restrictedSwitchingBehaviorConditions:)`,
`PrimaryConstituentDeviceSwitchingBehavior` (`.unsupported` / `.auto` / `.restricted` / `.locked`),
`fallbackPrimaryConstituentDevices` — all iOS 15.0+.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.enum)

Default is `.auto` where supported, `.unsupported` otherwise. `.auto` *"places no restrictions on when a
camera switch can occur."* Apple's stated rationale:

> "When multiple constituent cameras can achieve a requested zoom factor, the virtual device chooses the
> best camera for the scene… Secondary conditions are focus and exposure."

This API is the mitigation for apps that must use a virtual device. **This app should not need it** — it is
irrelevant on a single physical device.

### Can iOS still switch the active sensor mid-session on a single physical device?

**No Apple documentation states that a single physical `AVCaptureDevice` ever switches sensors.** But three
things can still move under you:

1. **Secondary native resolution zoom.** `AVCaptureDevice.Format.secondaryNativeResolutionZoomFactors`
   (iOS 16.0+): *"Devices that provide secondary native resolution zoom factors can switch their pixel
   sampling mode dynamically to produce high-fidelity images without upscaling at a fixed zoom factor
   beyond `1.0`."* This is a **readout-mode change within one physical camera** — the iPhone 15 Pro "2x"
   crop. **Apple documents no way to lock or disable it.** However, the Bayer RAW rule requiring
   `videoZoomFactor == 1.0` keeps you off every secondary factor by construction.
   [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/secondarynativeresolutionzoomfactors)

2. **The session can seize `activeFormat`.** Verbatim: *"In iOS, a device's active format and a capture
   session's `sessionPreset` are mutually exclusive… if you set a preset on a capture session, **the session
   assumes control of its input devices, and configures their active format appropriately**."* Pin
   `activeFormat` explicitly (which forces the session to `.inputPriority`) and KVO-observe it.
   [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat)
   Note this is in tension with the WWDC16 `.photo` preset advice — pick one and verify the resulting format
   has `isHighestPhotoQualitySupported == true`.

3. **System pressure.** *"If during a capture session the total system pressure reaches excessive levels,
   the capture system automatically shuts down… **Under less heavy pressure, the system may automatically
   reduce capture quality.**"* What "reduce capture quality" means mechanically is **undocumented**. The
   session interruption reason `.videoDeviceNotAvailableDueToSystemPressure` is the thermal failure mode to
   watch.
   [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempressurestate-swift.class) ·
   [P1](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason)

Also documented: *"Photo capture is not supported when AVCaptureDevice has selected
AVCaptureColorSpace_AppleLog or AVCaptureColorSpace_AppleLog2 as color space."* (header, P1-mirror.)

---

## Sub-question 4 — Exposure determinism

### The API

```swift
func setExposureModeCustom(duration: CMTime, iso ISO: Float,
                           completionHandler handler: (@Sendable (CMTime) -> Void)? = nil)
```
iOS 8.0+. *"Sets the exposure mode to a custom state, and locks exposure duration and ISO at explicit
values."* Header adds: **"This is the only way of setting exposureDuration and ISO."** Throws
`NSRangeException` out of range, `NSGenericException` without `lockForConfiguration()`.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))

The completion handler is genuinely useful for a capture log: *"The system passes a time value that matches
that of the first buffer to which its applied all settings… synchronized to the device clock, and you must
convert the timestamp to the `synchronizationClock` prior to comparison with the timestamps of buffers
delivered through an `AVCaptureVideoDataOutput`."* Multiple calls complete FIFO.

Also: *"Changes made to the exposure duration may result in changes to `activeVideoMinFrameDuration` or
`activeVideoMaxFrameDuration`."*

### The single most important documented fact in this ticket

From `exposureMode` and `setExposureModeCustom` (P1, and identically in the header):

> "When using `AVCapturePhotoOutput` to capture photos, the `photoQualityPrioritization` property of
> `AVCapturePhotoSettings` defaults to `balanced`, which allows photo capture to **temporarily override the
> capture device's exposure duration and ISO** if the scene is dark enough to require multi-image fusion to
> improve quality. **To ensure that the system honors the device exposure duration and ISO values while in
> `custom` or `locked` mode, you must set photo quality prioritization to `speed`.**"

And from `AVCapturePhotoOutput.h`, the Bayer RAW capture rules:

> "Bayer RAW rules (isBayerRAWPixelFormat: returns yes for rawPhotoPixelFormatType):
> - **photoQualityPrioritization must be set to AVCapturePhotoQualityPrioritizationSpeed**"

**These are the same lever.** Requesting Bayer RAW *forces* the exact setting that Apple documents as the
precondition for custom exposure being honoured. Set
`photoOutput.maxPhotoQualityPrioritization = .speed` before `startRunning()` too — and note the header
warning that setting `maxPhotoQualityPrioritization` to `.quality` *"will turn on optical image
stabilization"*, which you emphatically do not want.

### Range: full 1 s ceiling / 1/2000 s floor?

**Not answerable from Apple documentation.** `minExposureDuration`, `maxExposureDuration`, `minISO`, `maxISO`
are properties of `AVCaptureDevice.Format` — so they vary per `activeFormat` by construction — but Apple
publishes **no discussion text on any of the four** and **no numeric values for any iPhone**.

[minExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/minexposureduration) ·
[maxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/maxexposureduration) ·
[minISO](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/miniso) ·
[maxISO](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/maxiso)

What is documented is the coupling: `exposureDuration` is *"between the active format's
minExposureDuration and maxExposureDuration"*; `iso` is *"between the active format's minISO and maxISO"*.
And for manual brackets specifically, the header rule: *"For manual exposure brackets, ISO value must be
within the source device activeFormat's minISO and maxISO values"*, same for duration.

The map's 1 s / 1/2000 s figures are **project-measured on the device**, and that is the right status for
them. Enumerate `device.formats` at runtime and record the limits in the capture log rather than assuming.

### Does `.custom` hold across a bracket?

**Yes for manual-exposure brackets, by construction** — each frame carries its own explicit
`exposureDuration` and `iso` in an `AVCaptureManualExposureBracketedStillImageSettings`, so there is no
"holding" required. Apple validates each against the active format's limits.

For the underlying device state, Apple is less reassuring:

- The `photoQualityPrioritization` override above is the documented mechanism by which custom exposure fails
  to hold shot-to-shot. Mitigated by `.speed`, which Bayer RAW forces.
- The header states plainly that the system can change the mode itself: *"Clients can observe **automatic
  changes** to the receiver's exposureMode by key value observing this property."* Apple **does not
  enumerate when.**
- Apple documents resets for *neighbouring* properties and pointedly not for `exposureMode`:
  `activeMaxExposureDuration` *"resets to the default max exposure duration"* on `activeFormat` or
  `sessionPreset` change; `isGlobalToneMappingEnabled` *"resets to its default value of `false`"* when you
  change the active format, add the device's input to a session, or change the preset.
- **Undocumented:** whether `exposureMode` / `exposureDuration` / `iso` survive `stopRunning()`/
  `startRunning()`, session interruption, `activeFormat` change, or `sessionPreset` change. Treat as
  reset-on-anything: re-apply, read back, and record.
- `isAdjustingExposure` exists (iOS 4.0+, KVO) but Apple **never documents what it returns while
  `exposureMode == .custom`.**
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isadjustingexposure)

**Sentinel race, documented by Apple.** On `currentISO`: *"A device may be adjusting ISO at the time of the
call, in which case the value set may differ from the value of the `iso` property."* The header carries the
identical caveat for `AVCaptureExposureDurationCurrent`. **Never pass `AVCaptureISOCurrent` /
`AVCaptureExposureDurationCurrent` when you need repeatability** — pass explicit values.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/currentiso)

### Exposure bias — separate, and inert in `.custom`

Apple answers this one directly:

> "When the device exposure mode is `continuousAutoExposure` or `locked`, the bias affects both metering
> (`exposureTargetOffset`), and the actual exposure level (`exposureDuration` and `iso`). **When the exposure
> mode is `custom`, it only affects metering.**"
> [P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetbias)

So bias is settable but has **no documented effect on the actual exposure level in `.custom`**. Note
`.locked` is *not* like `.custom` here — in `.locked`, bias does move duration and ISO. Use `.custom`.

**Does bias leak into RAW? Undocumented.** Apple makes no statement anywhere about bias applying differently
to RAW versus processed output. What bounds the question: in `.locked`/`.continuousAutoExposure` bias
changes duration and ISO, which necessarily changes the Bayer data; in `.custom` it changes neither. So on
Apple's own documented mechanics, **in `.custom` mode bias cannot reach the sensor data** — but Apple never
says that in those words.

Corroboration only (Apple Developer Forums, no staff reply, C): developers report a "hidden exposure
compensation" in iPhone DNGs surfacing as the DNG `BaselineExposure` tag.
<https://developer.apple.com/forums/thread/66998> · <https://developer.apple.com/forums/thread/689790>
WWDC21 (P1) confirms Apple deliberately uses that tag — *"We use the BaselineExposure tag because ProRAW
images adapt to the dynamic range of the scene"* — but says so **about ProRAW**, not Bayer. A third-party
exiftool dump of an iPhone 16 Pro Max **ProRAW** DNG shows `Baseline Exposure : -2.353936195` (C, one
sample): <https://github.com/Exiv2/exiv2/issues/3041>. **Whether Bayer DNGs carry a non-zero
`BaselineExposure` is unestablished and worth measuring.**

### Local tone mapping — the residual adaptation

This is the most credible threat to photometric repeatability, and it is only Apple-attributable, not
documented. From an Apple Staff "Media Engineer" on the Developer Forums (P2), replying to a report of
luminance drift on iPhone 14 Pro with exposure locked/custom and WB locked:

> "What you are seeing is called local tone mapping, which is still active even when your exposure is
> locked… You can override local tone mapping by setting the AVCaptureDevice property
> `globalToneMappingEnabled`… **It will still adapt slightly, but less noticeably.**"
> <https://developer.apple.com/forums/thread/780406>

Documented behaviour of the mitigation: *"Normally the active camera uses adaptive, local tone curves… If
set to its default value of `false`, the framework may apply different tone maps to different pixels in an
image."* and *"When you enable global tone mapping, an `AVCapturePhotoOutput` object connected to the device
input's session disables all forms of still image fusion."* Gate on
`activeFormat.isGlobalToneMappingSupported`; note the resets listed above.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isglobaltonemappingenabled)

**Critical caveat: the forum exchange is about the rendered image. Whether local tone mapping touches the
Bayer path at all is undocumented, and tone mapping is by definition a post-demosaic render operation.**
It is plausible that Bayer RAW is immune. Do not assume either way — measure.

### Exposure metadata in the DNG

Apple documents the plumbing and none of the contents. `AVCapturePhoto.metadata` (iOS 11.0+): *"See
`CGImageProperties` for possible keys and values."* — that is the entire discussion.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephoto/metadata)
`fileDataRepresentation()` returns *"the data in the industry-standard DNG file format"* for RAW photos.

**Apple nowhere documents that DNG `ExposureTime` equals the duration you passed to
`setExposureModeCustom`, nor that `ISOSpeedRatings` equals your `iso`.** There is no Apple statement mapping
AVFoundation exposure state to written EXIF/DNG tag values. Verify empirically. This is exactly why the map
calls for a capture log written beside the frames rather than reconstructed from EXIF.

---

## Sub-question 5 — White-balance determinism

### Can gains be pinned to a fixed Daylight value?

**Yes, with three documented traps.**

```swift
func setWhiteBalanceModeLocked(with whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains,
                               completionHandler handler: (@Sendable (CMTime) -> Void)? = nil)
```
iOS 8.0+.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:))

Compute the gains for a target colour temperature with the device-specific converter,
`deviceWhiteBalanceGains(for: WhiteBalanceTemperatureAndTintValues)` (iOS 8.0+):
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicewhitebalancegains(for:)-3wtsa)

> "You may pass any temperature and tint values and corresponding white balance gains will be produced.
> Note, though, that **some temperature and tint combinations yield out-of-range device RGB values that will
> cause an exception to be thrown if passed directly to `setWhiteBalanceModeLocked(with:completionHandler:)`.
> Be sure to verify that the red, green, and blue gain values are within the range of
> [1.0 - `maxWhiteBalanceGain`].**"

**Trap 1 — capability gate.** `isLockingWhiteBalanceWithCustomDeviceGainsSupported` (iOS 10.0+): *"If the
value is `false`, calling the `setWhiteBalanceModeLocked(with:completionHandler:)` method with a white
balance gains value other than `currentWhiteBalanceGains` throws an exception."* Check this before assuming
a fixed Daylight lock is possible on iPhone 15 Pro.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islockingwhitebalancewithcustomdevicegainssupported)

**Trap 2 — silent normalization.** *"**The system normalizes gain values to the minimum channel value to
avoid brightness changes (for example, `R:2 G:2 B:4` normalizes to `R:1 G:1 B:2`).**"* What you set is not
what you read back. Always read `deviceWhiteBalanceGains` after setting, and log the read-back value, not
the requested one.

**Trap 3 — `maxWhiteBalanceGain` is undocumented numerically.** Apple's only discussion sentence is *"This
property doesn't change for the life of the object."* No value published for any iPhone.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/maxwhitebalancegain)

Supporting API: `chromaticityValues(for:)`, `temperatureAndTintValues(for:)`,
`deviceWhiteBalanceGains(for: WhiteBalanceChromaticityValues)`, all iOS 8.0+ instance methods (device-
specific, not free functions). `WhiteBalanceTemperatureAndTintValues { temperature: Float /* kelvin */;
tint: Float /* -150…+150 */ }`. `grayWorldDeviceWhiteBalanceGains` is available if a grey-card-derived
neutral is ever wanted for a calibration mode.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/grayworlddevicewhitebalancegains)

**New in iOS 26** — a direct temperature setter, avoiding the manual clamp dance:

```swift
func setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues,
                               handler: ((CMTime) -> Void)? = nil)
```
iOS 26.0+, plus presets `.daylight`, `.cloudy`, `.shadow`, `.tungsten`, `.fluorescent`.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(whitebalancetemperatureandtintvalues:handler:))
**Apple publishes no numeric K/tint for any preset** — `.daylight` is described only as *"Temperature and
tint values ideal for scenes illuminated with natural daylight."* **Do not assume `.daylight == 5500K`.**
For a known, loggable value, construct `init(temperature: 5500, tint: 0)` explicitly.

Also documented in the header but not on the web: `AVCaptureWhiteBalanceModeAutoWhiteBalance` means *"the
device should automatically adjust white balance once and then change the white balance mode to
AVCaptureWhiteBalanceModeLocked"* — a one-shot AWB that auto-transitions the mode. And per the header,
`isAdjustingWhiteBalance` is defined against the *auto* modes specifically, so it should read `false` in
`.locked`.

### Do the gains land in RAW metadata as written?

**Completely undocumented. This is the highest-risk unknown in the ticket, and it sits directly on the
project's critical path.**

Specifically, no Apple source states:

- whether white balance gains are applied to Bayer RAW **pixel data** before it reaches the app;
- whether the gains set via `setWhiteBalanceModeLocked(with:)` are written to the DNG `AsShotNeutral` tag;
- whether `AsShotNeutral` in an AVFoundation-produced DNG reflects the **locked** gains or gains
  **re-metered at capture time**;
- whether `whiteBalanceMode == .locked` is honoured at all during a photo capture. Note the
  `photoQualityPrioritization` override warning names **only exposure duration and ISO**. Silence about
  white balance is not a guarantee either way.

What exists is a key *definition*, not a statement about what AVFoundation writes:
`kCGImagePropertyDNGAsShotNeutral` — *"The selected white balance at the time of capture, encoded as the
coordinates of a neutral color in linear reference space values."* (iOS 10.0+). Siblings:
`kCGImagePropertyDNGAsShotWhiteXY`, `kCGImagePropertyDNGAnalogBalance`, `kCGImagePropertyDNGForwardMatrix1/2`.
[P1](https://developer.apple.com/documentation/imageio/kcgimagepropertydngasshotneutral)

WWDC21's list of DNG tags Apple writes (`LinearizationTable`, `BaselineExposure`, `BaselineSharpness`,
`ProfileGainTableMap`, `ProfileToneCurve`) is **explicitly about ProRAW, and never mentions
`AsShotNeutral`.** WWDC16 adds only: *"DNG is a standard way of just storing bits and metadata… It's still
up to individual RAW converters to decide how to interpret those ingredients."*

Corroboration only (C, one sample, third-party issue tracker): an exiftool dump of an iPhone 16 Pro Max
**ProRAW** DNG shows `As Shot Neutral : 1 1 1`. An identity `AsShotNeutral` is consistent with ProRAW pixels
already being white-balanced in-pixel — which would mean locked gains are **not** recoverable from that tag
in a ProRAW file. Says nothing about Bayer. Treat as a hypothesis to test.
<https://github.com/Exiv2/exiv2/issues/3041>

**Required measurement.** On iPhone 15 Pro, same scene, same station: capture Bayer RAW with (a)
`.locked` at explicit gains G1, (b) `.locked` at clearly different gains G2. Diff the DNG `AsShotNeutral` /
`AsShotWhiteXY` tags **and** the raw CFA channel ratios. Three outcomes, each with a different consequence
for the app:
- tags differ, pixels identical → gains are metadata-only; pinning WB is purely a metadata determinism
  measure, which is what the map assumes. Best case.
- tags differ **and** pixels differ → gains touch the sensor path; WB must be treated as a photometric
  parameter, not a metadata one.
- tags identical → the lock is not reaching the DNG at all; the capture log must carry the gains itself.

---

## Sub-question 6 — Bracketing API

### RAW brackets are supported, with manual exposure

`AVCapturePhotoBracketSettings` — *"A specification of the features and settings to use for a photo capture
request that captures multiple images with varied settings."* iOS 10.0+, not deprecated.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)

The RAW-capable initializer, **iOS 11.0+**:

```swift
convenience init(rawPixelFormatType: OSType, rawFileType: AVFileType?,
                 processedFormat: [String : Any]?, processedFileType: AVFileType?,
                 bracketedSettings: [AVCaptureBracketedStillImageSettings])
```

with `rawPixelFormatType` documented as *"The Bayer RAW pixel format type to use for capture."* and
`bracketedSettings` as *"An array of either `AVCaptureManualExposureBracketedStillImageSettings` or
`AVCaptureAutoExposureBracketedStillImageSettings` objects… All image settings objects in this array must be
the same type."*
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings/init(rawpixelformattype:rawfiletype:processedformat:processedfiletype:bracketedsettings:))

For RAW-only brackets use the 3-argument
`init(rawPixelFormatType:processedFormat:bracketedSettings:)` with `processedFormat: nil`.

`AVCaptureManualExposureBracketedStillImageSettings` (iOS 8.0+) — *"A configuration for defining bracketed
photo captures in terms of specific exposure and ISO values."* Factory:
`class func manualExposureSettings(exposureDuration: CMTime, iso: Float) -> Self`. Sentinels
`AVCaptureExposureDurationCurrent` / `AVCaptureISOCurrent` hold a channel unchanged — **do not use them
here**, per the documented race in sub-question 4.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturemanualexposurebracketedstillimagesettings)

Apple's own confirmation that this combination works, WWDC16/501 (P1):

> "We do support RAW brackets, so you can take a bracket of three RAW images, for instance."
> "RAW plus processed brackets are supported… if I'm doing a bracket of three, I'm going to get three RAWs
> and three JPEGs."

Delivery: the RAW delegate callback *"is fired bracketedSettings.count times (once for each photo in the
bracket)"* and each invocation carries the corresponding `AVCaptureBracketedStillImageSettings` back —
which gives the app frame-to-request correlation for free, and is exactly what the map's "all frames in a
bracket share one station and one pose" grouping needs.

### Documentation conflict — resolved

The published `AVCapturePhotoBracketSettings` page says:

> "Bracketed capture supports only the `isHighResolutionPhotoEnabled` and `previewPhotoFormat` settings
> defined by the `AVCapturePhotoSettings` superclass. Bracketed capture does not support flash, auto
> stabilization, or Live Photos—attempting to set any of the corresponding properties raises an exception."

Read literally, that would forbid setting `photoQualityPrioritization` on a bracket — which, combined with
the Bayer rule that it *must* be `.speed`, would make Bayer RAW brackets impossible. **It does not.** That
DocC text dates from iOS 10 and predates `photoQualityPrioritization` (iOS 13.0). The current header
(`iPhoneOS26.5.sdk`, P1-mirror) states the restriction as a **closed negative list** that does not include
it:

> "AVCapturePhotoBracketSettings do not support flashMode, autoStillImageStabilizationEnabled,
> livePhotoMovieFileURL or livePhotoMovieMetadata."

`photoQualityPrioritization` is declared on `AVCapturePhotoSettings` (iOS 13.0+, default `.balanced`) and
the header's Bayer rules apply it to all Bayer captures without carving out brackets. **Trust the header;
set `photoQualityPrioritization = .speed` on the bracket settings object.** Confirm on device early — this
is a cheap test and it gates the whole bracket design.

### Documented bracket validation rules

From `-capturePhotoWithSettings:delegate:` (header, P1-mirror) — each throws `NSInvalidArgumentException`:

> "Bracketed capture rules:
> - bracketedSettings.count must be <= the receiver's maxBracketedCapturePhotoCount property.
> - For manual exposure brackets, ISO value must be within the source device activeFormat's minISO and
>   maxISO values.
> - For manual exposure brackets, exposureDuration value must be within the source device activeFormat's
>   minExposureDuration and maxExposureDuration values.
> - For auto exposure brackets, exposureTargetBias value must be within the source device's
>   minExposureTargetBias and maxExposureTargetBias values."

Plus `NSInvalidArgumentException` if `bracketedSettings` is nil, empty, or mixes subclasses.

### The bracket-count ceiling — the real open question

`maxBracketedCapturePhotoCount` (iOS 10.0+):

> "The maximum number of photos per capture depends on the size and format of images to be captured."
> "This property's value can change if the `sessionPreset` property of the current capture session or the
> `activeFormat` property of the underlying capture device changes."
> "Not all devices and capture formats support bracketed capture. If the current device or active format
> does not support bracketed capture, this property's value is zero."

Header adds the mechanism: *"AVCapturePhotoOutput can only satisfy a limited number of image requests in a
single bracket without exhausting system resources."*
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxbracketedcapturephotocount)

**Apple publishes no value for any device or format.** RAW buffers are the largest case — WWDC16: *"RAW
capture requires very large buffers"* and *"bracketed capture requires multiple buffers to return multiple
images to the client."* So the RAW-bracket ceiling on iPhone 15 Pro is **undocumented and could plausibly
be small, or zero for some formats.** This is the one number that must be measured before the bracket-ladder
ticket can be closed. Probe it per sensor and per candidate `activeFormat`, and KVO it.

### The fallback, if the ceiling is too low

Sequential single captures with re-applied exposure. **Apple documents no shot-to-shot or inter-frame time
for any capture type**, so the cost cannot be quantified from primary sources. What is documented:

- `setPreparedPhotoSettingsArray(_:completionHandler:)` (iOS 10.0+) — *"Some types of photo capture, such as
  bracketed captures and RAW captures, require the photo output to allocate additional buffers or prepare
  other resources. To prevent photo capture requests from executing slowly due to lazy resource allocation,
  you may call this method with an array of settings objects representative of the types of capture you will
  be performing… Preparation for photo capture is always optional."* Prepare with a representative RAW
  settings object before `startRunning()` regardless of which path you take.
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/setpreparedphotosettingsarray(_:completionhandler:))
- `AVCapturePhotoOutput.captureReadiness` (iOS 17.0+) — *"A value that specifies whether the photo output is
  ready to respond to new capture requests in a timely manner."* KVO-observable; this is the documented way
  to pace a sequential ladder without guessing at timings.
  [P1](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/capturereadiness-swift.property)
- `AVCaptureResolvedPhotoSettings.photoProcessingTimeRange` — *"The time range in which to expect the system
  to deliver the photo to the delegate."* Per-capture, and worth logging.
- Header: *"Clients need not wait for a capture photo request to complete before issuing another request."*

The sequential fallback also costs determinism, not just time: each frame needs its own
`setExposureModeCustom` round-trip with completion-handler confirmation, and the device's exposure state is
not documented to survive anything. The bracket path avoids that entirely, which is why the
`maxBracketedCapturePhotoCount` probe matters.

`isLensStabilizationEnabled` (default `false`, gated on
`isLensStabilizationDuringBracketedCaptureSupported`) applies OIS across the whole bracket. Leave it
`false` for calibration work — it moves the lens, and the map's premise is a fixed optical path per station.

---

## Sub-question 7 — Per-frame adaptation that cannot be disabled

### The complete list of RAW carve-outs Apple actually documents

From `AVCapturePhotoSettings.rawPhotoPixelFormatType` — *"An identifier for the Bayer RAW pixel format to
deliver captured RAW photos in."*
[P1](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/rawphotopixelformattype)

> "When capturing RAW images, the following requirements apply:
> - The `isAutoStillImageStabilizationEnabled` setting must be `false`.
> - Your delegate object must implement the `photoOutput(_:didFinishProcessingRawPhoto:…)` method.
> - The `isHighResolutionPhotoEnabled` setting may be `true` or `false`, but that setting applies only to
>   the separate processed image."

Plus two properties whose *default* text carries a RAW carve-out, from the header:

- `autoStillImageStabilizationEnabled` — *"Default is YES **unless you are capturing a Bayer RAW photo
  (Bayer RAW photos may not be processed by definition) or a bracket using AVCapturePhotoBracketSettings**."*
- `autoVirtualDeviceFusionEnabled` — *"Default is YES **unless you are capturing a RAW photo … or a bracket
  using AVCapturePhotoBracketSettings**."*
- `autoRedEyeReductionEnabled` — same pattern: default YES *"unless you are capturing a bracket … or a RAW
  photo without a processed photo. For RAW photos with a processed photo the red-eye reduction will be
  applied to the processed photo only (RAW photos by definition are not processed)."*

Note the pattern: **Bayer RAW and bracketing each independently turn these off.** This app does both.

And the hard-coded one from `AVCaptureDevice.h` (P1-mirror), which matters most for the ultra-wide:

> "Beware though that **RAW photo captures never have GDC applied**, regardless of the value of
> `AVCaptureDevice.geometricDistortionCorrectionEnabled`."

So ultra-wide Bayer RAW arrives geometrically uncorrected — correct for calibration, and it means the
distortion model belongs entirely downstream.

Also, from the header on sensor-orientation compensation: *"compensation is never applied to Bayer RAW or
Apple ProRaw captures."*

### Zero shutter lag, responsive capture, deferred delivery

`isZeroShutterLagEnabled` / `isResponsiveCaptureEnabled` / `isFastCapturePrioritizationEnabled` /
`isAutoDeferredPhotoDeliveryEnabled` — all iOS 17.0+. The published DocC pages carry **no discussion text
at all**. The header does:

> "For apps linked on or after iOS 17 zero shutter lag is automatically enabled when supported. Enabling
> zero shutter lag reduces or eliminates shutter lag when using AVCapturePhotoQualityPrioritizationBalanced
> or Quality… **The timestamp of the AVCapturePhoto may be slightly earlier than when
> -capturePhotoWithSettings:delegate: was called.** … **Zero shutter lag isn't available when using manual
> exposure or bracketed capture.**"

WWDC23 session 10105 (P1) says the same and describes the mechanism:

> "With Zero Shutter Lag enabled, the camera pipeline keeps a rolling ring buffer of frames from the past…
> you tap to capture, and the camera pipeline does a little bit of time travel, grabs frames from the ring
> buffer, and fuses them together."
> "Certain types of still image captures such as flash captures, **configuring the AVCaptureDevice for a
> manual exposure, bracketed captures**, and constituent photo delivery … don't get Zero Shutter Lag."
> "We've enabled Zero Shutter Lag on apps that link on or after iOS 17 for AVCaptureSessionPresets and
> AVCaptureDeviceFormats where isHighestPhotoQualitySupported is true."
> <https://developer.apple.com/videos/play/wwdc2023/10105/>

**This app is doubly excluded** — manual exposure *and* bracketed capture. Two further points: ZSL only
engages at `.balanced` or `.quality`, and Bayer RAW forces `.speed`, so it is excluded a third way. Still
set `isZeroShutterLagEnabled = false` (and consequently `isResponsiveCaptureEnabled = false`,
`isFastCapturePrioritizationEnabled = false`) explicitly, both for belt-and-braces and because the ZSL
timestamp caveat is fatal to any future IMU-synchronisation work.

**Note the RAW omission.** The WWDC23 exclusion list conspicuously does *not* name RAW. **Whether a
non-bracketed, non-manual-exposure Bayer RAW capture would receive ZSL is undocumented.** Irrelevant here
given the triple exclusion, but do not generalise the claim.

`isFastCapturePrioritizationEnabled` is the one to be most careful about, per the header: *"Fast capture
prioritization allows capture quality to be automatically reduced from the selected
AVCapturePhotoQualityPrioritization"* — it only applies when `responsiveCaptureEnabled` is YES, so keeping
that off closes it.

### Deep Fusion, Smart HDR, semantic rendering

**There is no `isDeepFusionSupported` and no `isAutoDeepFusionEnabled` anywhere in AVFoundation.** This is a
confirmed negative, not a gap: the full topic listings for `AVCapturePhotoOutput` and `AVCapturePhotoSettings`
contain neither. Deep Fusion appears only in WWDC narration, never as API.

The only documented lever is `photoQualityPrioritization` / `maxPhotoQualityPrioritization`, whose docs
describe the category without naming the algorithms — *"a variety of techniques to improve photo quality…
reducing noise, preserving detail in low light, and freezing motion"*. **The mapping from prioritization
level to specific algorithms is never stated by Apple.** Since Bayer RAW forces `.speed` — the lowest level
— this is closed off by the format choice rather than by an explicit control.

Semantic rendering is structurally absent from the Bayer path: WWDC21 (P1) states *"portrait effects matte
and semantic segmentation skin and sky mattes are only supported with ProRAW"*, and the ProRAW capture rules
in the header say `enabledSemanticSegmentationMatteTypes` *"will automatically be cleared"* even there.

HDR requires explicit attention because it defaults **on**: `automaticallyAdjustsVideoHDREnabled` — *"By
default, this value is `true`, and a capture device automatically enables `isVideoHDREnabled` if it's a good
fit for the active format."* Set it `false`, then set `isVideoHDREnabled = false`. One documented
un-disableable case: *"The device ignores the value of this property when `activeColorSpace` is HLG BT2020
color space because HDR is effectively always on and can't be disabled."* — so avoid that colour space.
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/automaticallyadjustsvideohdrenabled) ·
[P1](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvideohdrenabled)

`isContentAwareDistortionCorrectionEnabled` (iOS 14.1+) must be set before `startRunning()`; Apple notes it
*"may result in a small change in the field of view… The amount lost or gained is content specific and
varies from photo to photo."* Leave it off. (It is auto-disabled for ProRAW; **whether it is auto-disabled
for Bayer RAW is not stated** — set it explicitly.)

### Lens shading, black level, per-frame gain — fully undocumented

**Apple documents nothing about what per-frame sensor corrections it applies to Bayer RAW before writing the
DNG.** No AVFoundation page mentions lens shading, vignetting correction, black level subtraction, PDAF
pixel repair, or per-frame gain in the context of RAW capture. This is a genuine void, not an oversight in
the search.

What exists nearby, and what it does and does not prove:

- ImageIO defines DNG keys for these corrections — `kCGImagePropertyDNGOpcodeList1/2/3`,
  `kCGImagePropertyDNGFixVignetteRadial` (*"An opcode to apply a gain function to an image to correct
  vignetting"*), `kCGImagePropertyDNGBlackLevel` (*"The zero light encoding level, specified as a repeating
  pattern"*), `BlackLevelDeltaH/V`, `WarpRectilinear`, `WarpFisheye`. These are **read-side key definitions.
  They say nothing about what AVFoundation writes.**
  [P1](https://developer.apple.com/documentation/imageio/dng-image-properties)
  (There is no `OpacityCorrection` constant in Apple's DNG properties — that name is not Apple's.)
- Core Image's `CIRAWFilter.isLensCorrectionEnabled` (iOS 15.0+) — *"A Boolean that indicates whether to
  enable lens correction. The default value varies by image."* This shows Apple's **decoder** can apply lens
  correction to a RAW file; it says nothing about what the **capture** pipeline baked in.
- WWDC21 lists DNG tags Apple writes **for ProRAW only**. Bayer RAW's tag set is never enumerated.

For a project whose premise is that every photometric parameter is fixed, measured, or recorded, **the
correct posture is: assume nothing about what Apple has already applied to the Bayer data, and measure flat
fields and dark frames on the device.** That is already a stretch goal on the map; this finding argues for
promoting it. It also independently justifies the map's stance that `NoiseProfile` is a sanity band, never a
substitute for measured calibration.

### The only documented ground truth for what was applied

`AVCaptureResolvedPhotoSettings` — *"An immutable object produced by callbacks in each and every
AVCapturePhotoCaptureDelegate protocol method… AVCapturePhotoOutput begins the capture, resolves the
uncertain settings, and in its first callback informs you of its choices."* Its `uniqueID` matches the
request's.
[P1](https://developer.apple.com/documentation/avfoundation/avcaptureresolvedphotosettings)

Members worth writing into the capture log: `isFlashEnabled`, `isVirtualDeviceFusionEnabled`,
`isFastCapturePrioritizationEnabled`, `isContentAwareDistortionCorrectionEnabled`,
`isStillImageStabilizationEnabled`, `isDualCameraFusionEnabled`, `rawPhotoDimensions`,
`photoProcessingTimeRange`, `expectedPhotoCount`.

**There is no resolved flag for HDR, noise reduction, tone mapping, lens shading, or Deep Fusion.** The
observable surface stops well short of the processing surface — which is the strongest single argument for
the map's "capture log written beside the frames" requirement.

---

## Sub-question 8 — Platform gating

### Entitlements: none

**No entitlement, capability, or App Store restriction gates RAW or ProRAW capture on iOS.** Searches of
Apple's documentation and of both SDK headers turn up nothing. RAW is ordinary `AVCapturePhotoOutput`
functionality.

What is required is the standard camera privacy gate:

- `NSCameraUsageDescription` in `Info.plist` — *"A message that tells people why the app is requesting
  access to the device's camera."*
- `AVCaptureDevice.authorizationStatus(for: .video)` then `AVCaptureDevice.requestAccess(for: .video)`.
- *"Your app needs to contain the appropriate key in its `Info.plist` file … **before** it requests
  authorization or attempts to use a capture device. Otherwise, the system terminates your app."*
- `com.apple.security.device.camera` is a **macOS-only** entitlement; not applicable.
- Saving to the Photos library additionally needs `PHPhotoLibrary.requestAuthorization(for: .addOnly)` —
  though for this app, writing DNGs into the app container beside the capture log is likely preferable to
  Photos ingest.

[P1](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)

### Minimum iOS version

| Capability | Symbol | Min iOS |
|---|---|---|
| Bayer RAW capture | `availableRawPhotoPixelFormatTypes`, `init(rawPixelFormatType:)` | 10.0 |
| Custom exposure, WB lock with custom gains, all bracket settings types | `setExposureModeCustom`, `setWhiteBalanceModeLocked(with:)`, `AVCaptureManualExposureBracketedStillImageSettings` | 8.0 |
| **RAW bracket with explicit file types** | `init(rawPixelFormatType:rawFileType:processedFormat:processedFileType:bracketedSettings:)` | **11.0** |
| Ultra-wide device type | `.builtInUltraWideCamera` | 13.0 |
| `photoQualityPrioritization` (mandatory `.speed` for Bayer) | `AVCapturePhotoSettings.photoQualityPrioritization` | **13.0** |
| Global tone mapping override | `isGlobalToneMappingEnabled` | 13.0 |
| Bayer/ProRAW format discrimination | `isBayerRAWPixelFormat(_:)` | 14.3 |
| Constituent-switching control (not needed on physical devices) | `setPrimaryConstituentDeviceSwitchingBehavior(...)` | 15.0 |
| `maxPhotoDimensions`, `supportedMaxPhotoDimensions` | replaces `isHighResolutionCaptureEnabled` (deprecated 16.0) | 16.0 |
| **Explicitly disabling ZSL / responsive / fast-capture prioritization** | `isZeroShutterLagEnabled` etc. | **17.0** |
| Direct temperature WB lock, `.daylight` preset | `setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues:)` | 26.0 |

**Functional floor: iOS 13.0** (`photoQualityPrioritization` is mandatory for Bayer RAW and ultra-wide needs
13.0). **Recommended floor: iOS 17.0** — below that you cannot explicitly disable zero shutter lag, and ZSL
auto-enables for apps linked on or after iOS 17. iPhone 15 Pro shipped with iOS 17, so iOS 17.0 costs
nothing. iOS 26 adds only convenience.

### Resolution gating

12 MP only. 48 MP raw sensor data is not exposed to third-party apps — corroborated by Lux (C): *"we do not
get 48 raw sensor data from iOS. We've filed a request with Apple for this."* Apple's own WWDC26 session 304
discusses 24/48 MP exclusively in terms of `maxPhotoDimensions` and processed output, states *"only the
photo preset supports 24 and 48 megapixel photos"*, and says *"Setting maxPhotoDimensions is a request, not
a guarantee. The system looks at light level, scene, and available processing, and picks the best path it
can."* — and the header notes 24 MP *"is only serviced as 24MP via deferred photo delivery"*, a path this
app must not use. Nothing in that session extends 48 MP to Bayer RAW. Matches the map's locked constraint.

---

## Recommended capture configuration

Every line below traces to a citation above. Nothing here is inferred.

**Session setup, before `startRunning()`:**
1. Discover the target physical device via `AVCaptureDeviceDiscoverySession` — `.builtInWideAngleCamera`,
   `.builtInUltraWideCamera`, or `.builtInTelephotoCamera`. Never a virtual device.
2. `sessionPreset = .photo`, or pin `activeFormat` to one with `isHighestPhotoQualitySupported == true`
   (the two are mutually exclusive — choose deliberately). KVO-observe `activeFormat`.
3. Leave `isAppleProRAWEnabled` at its default `false`. Never set it.
4. `photoOutput.maxPhotoQualityPrioritization = .speed`.
5. `isZeroShutterLagEnabled = false`; `isResponsiveCaptureEnabled = false`;
   `isFastCapturePrioritizationEnabled = false`; `isAutoDeferredPhotoDeliveryEnabled = false`;
   `isContentAwareDistortionCorrectionEnabled = false`; `isVirtualDeviceConstituentPhotoDeliveryEnabled = false`.
6. `device.automaticallyAdjustsVideoHDREnabled = false`, then `isVideoHDREnabled = false`. Avoid HLG BT2020
   and Apple Log colour spaces.
7. `setPreparedPhotoSettingsArray` with a representative Bayer RAW bracket settings object.
8. Read and record `availableRawPhotoPixelFormatTypes`, `maxBracketedCapturePhotoCount`,
   `activeFormat.{minISO,maxISO,minExposureDuration,maxExposureDuration}`, `maxWhiteBalanceGain`.

**Per station, under `lockForConfiguration()`:**
9. `videoZoomFactor = 1.0`; verify the connection's `videoScaleAndCropFactor == 1.0`.
10. Compute Daylight gains via `deviceWhiteBalanceGains(for:)`, clamp to `[1.0, maxWhiteBalanceGain]`, call
    `setWhiteBalanceModeLocked(with:)`, then **read back** `deviceWhiteBalanceGains` and log the read-back.
11. Optionally `isGlobalToneMappingEnabled = true` (gate on `activeFormat.isGlobalToneMappingSupported`) —
    but re-check step 6 afterwards, since it resets on format/preset/input changes.

**Per bracket:**
12. Build `AVCaptureManualExposureBracketedStillImageSettings` with explicit duration and ISO per frame —
    never the `Current` sentinels. Vary shutter, not ISO, per the map.
13. `AVCapturePhotoBracketSettings(rawPixelFormatType:rawFileType:processedFormat:nil,processedFileType:nil,bracketedSettings:)`,
    with `photoQualityPrioritization = .speed` and `isLensStabilizationEnabled = false`.
14. Record `AVCaptureResolvedPhotoSettings` for every callback, and `photo.metadata`, into the capture log.
15. KVO `systemPressureState`, `AVCaptureSession.runtimeErrorNotification`, and
    `wasInterruptedNotification`; treat `.videoDeviceNotAvailableDueToSystemPressure` as a protocol abort.

---

## Open questions to settle on device before the dependent tickets

Ordered by how much design they gate.

1. **Does `photoQualityPrioritization = .speed` on an `AVCapturePhotoBracketSettings` with a Bayer format
   succeed?** Resolves the DocC/header conflict. Cheap; blocks the bracket-ladder ticket.
2. **What is `maxBracketedCapturePhotoCount` per sensor, per candidate `activeFormat`, for a RAW bracket?**
   If it is small or zero, the bracket ladder needs a sequential fallback and an inter-frame-time budget.
3. **White balance: metadata-only, or does it touch the Bayer pixels?** The three-outcome experiment in
   sub-question 5. Highest photometric risk in the ticket.
4. **Does ultra-wide actually offer a `14Bayer_*` format?** Project-measured yes; confirm from the app's own
   `availableRawPhotoPixelFormatTypes` read, since Apple never documents it.
5. **Does local tone mapping reach the Bayer path?** Fixed scene, fixed custom exposure, varying surround;
   compare raw CFA statistics with `isGlobalToneMappingEnabled` off and on.
6. **Do DNG `ExposureTime` / `ISOSpeedRatings` equal what was passed to `setExposureModeCustom`?** No Apple
   statement exists. Determines whether the capture log must carry them independently (it probably should
   regardless).
7. **Is `BaselineExposure` non-zero in Bayer DNGs?** Only ever discussed by Apple in the ProRAW context.
8. **Does the system Settings ProRAW toggle change anything for this app?** Test both states.
9. **Does the WWDC16 `.photo` preset requirement still bind?** Never restated, never rescinded.
10. **What timestamp does a captured frame carry, and in which clock domain?** The
    `setExposureModeCustom` completion handler documents a device-clock timestamp requiring conversion to
    `synchronizationClock`; whether `AVCapturePhoto` timestamps share that domain is not documented here and
    is the prerequisite the map already flags for the IMU axis.

---

## Sources

### Apple developer documentation (P1)

- [Capturing photos in RAW and Apple ProRAW formats](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats)
- [AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput)
- [availableRawPhotoPixelFormatTypes (Swift)](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotopixelformattypes-9t9k5) · [(ObjC)](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotopixelformattypes-5fatm)
- [availableRawPhotoFileTypes](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotofiletypes) · [supportedRawPhotoPixelFormatTypes(for:)](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/supportedrawphotopixelformattypes(for:))
- [isAppleProRAWSupported](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawsupported) · [isAppleProRAWEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawenabled)
- [isBayerRAWPixelFormat(_:)](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isbayerrawpixelformat(_:)) · [isAppleProRAWPixelFormat(_:)](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawpixelformat(_:))
- [AVCapturePhotoSettings.rawPhotoPixelFormatType](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/rawphotopixelformattype) · [init(rawPixelFormatType:rawFileType:processedFormat:processedFileType:)](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/init(rawpixelformattype:rawfiletype:processedformat:processedfiletype:))
- [AVCapturePhotoBracketSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings) · [init(rawPixelFormatType:rawFileType:processedFormat:processedFileType:bracketedSettings:)](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings/init(rawpixelformattype:rawfiletype:processedformat:processedfiletype:bracketedsettings:)) · [isLensStabilizationEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings/islensstabilizationenabled)
- [AVCaptureManualExposureBracketedStillImageSettings](https://developer.apple.com/documentation/avfoundation/avcapturemanualexposurebracketedstillimagesettings) · [AVCaptureAutoExposureBracketedStillImageSettings](https://developer.apple.com/documentation/avfoundation/avcaptureautoexposurebracketedstillimagesettings)
- [maxBracketedCapturePhotoCount](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxbracketedcapturephotocount) · [isLensStabilizationDuringBracketedCaptureSupported](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/islensstabilizationduringbracketedcapturesupported)
- [setPreparedPhotoSettingsArray(_:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/setpreparedphotosettingsarray(_:completionhandler:)) · [captureReadiness](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/capturereadiness-swift.property)
- [isZeroShutterLagEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iszeroshutterlagenabled) · [isResponsiveCaptureEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isresponsivecaptureenabled)
- [maxPhotoQualityPrioritization](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotoqualityprioritization) · [AVCapturePhotoSettings.photoQualityPrioritization](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/photoqualityprioritization)
- [isContentAwareDistortionCorrectionEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iscontentawaredistortioncorrectionenabled) · [isVirtualDeviceConstituentPhotoDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isvirtualdeviceconstituentphotodeliveryenabled) · [virtualDeviceConstituentPhotoDeliveryEnabledDevices](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/virtualdeviceconstituentphotodeliveryenableddevices)
- [AVCaptureResolvedPhotoSettings](https://developer.apple.com/documentation/avfoundation/avcaptureresolvedphotosettings) · [AVCapturePhoto.metadata](https://developer.apple.com/documentation/avfoundation/avcapturephoto/metadata) · [fileDataRepresentation()](https://developer.apple.com/documentation/avfoundation/avcapturephoto/filedatarepresentation()) · [AVCapturePhotoFileDataRepresentationCustomizer](https://developer.apple.com/documentation/avfoundation/avcapturephotofiledatarepresentationcustomizer)
- [builtInWideAngleCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinwideanglecamera) · [builtInUltraWideCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinultrawidecamera) · [builtInTelephotoCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintelephotocamera) · [builtInTripleCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintriplecamera) · [builtInDualWideCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtindualwidecamera)
- [DiscoverySession.init(deviceTypes:mediaType:position:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession/init(devicetypes:mediatype:position:)) · [constituentDevices](https://developer.apple.com/documentation/avfoundation/avcapturedevice/constituentdevices) · [activePrimaryConstituent](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeprimaryconstituent) · [virtualDeviceSwitchOverVideoZoomFactors](https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors)
- [PrimaryConstituentDeviceSwitchingBehavior](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.enum) · [setPrimaryConstituentDeviceSwitchingBehavior(_:restrictedSwitchingBehaviorConditions:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setprimaryconstituentdeviceswitchingbehavior(_:restrictedswitchingbehaviorconditions:))
- [activeFormat](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat) · [secondaryNativeResolutionZoomFactors](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/secondarynativeresolutionzoomfactors) · [isHighestPhotoQualitySupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/ishighestphotoqualitysupported) · [isHighPhotoQualitySupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/ishighphotoqualitysupported)
- [SystemPressureState](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempressurestate-swift.class) · [AVCaptureSession.InterruptionReason](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason) · [runtimeErrorNotification](https://developer.apple.com/documentation/avfoundation/avcapturesession/runtimeerrornotification)
- [setExposureModeCustom(duration:iso:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)) · [exposureMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuremode-swift.property) · [exposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration) · [iso](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso) · [currentISO](https://developer.apple.com/documentation/avfoundation/avcapturedevice/currentiso) · [currentExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/currentexposureduration) · [isAdjustingExposure](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isadjustingexposure)
- [exposureTargetBias](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetbias) · [exposureTargetOffset](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetoffset) · [activeMaxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration)
- [Format.minExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/minexposureduration) · [maxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/maxexposureduration) · [minISO](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/miniso) · [maxISO](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/maxiso)
- [setWhiteBalanceModeLocked(with:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:)) · [setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues:handler:) (iOS 26)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(whitebalancetemperatureandtintvalues:handler:)) · [deviceWhiteBalanceGains](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicewhitebalancegains) · [maxWhiteBalanceGain](https://developer.apple.com/documentation/avfoundation/avcapturedevice/maxwhitebalancegain) · [isLockingWhiteBalanceWithCustomDeviceGainsSupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islockingwhitebalancewithcustomdevicegainssupported) · [grayWorldDeviceWhiteBalanceGains](https://developer.apple.com/documentation/avfoundation/avcapturedevice/grayworlddevicewhitebalancegains) · [deviceWhiteBalanceGains(for:) temperature/tint](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicewhitebalancegains(for:)-3wtsa) · [.daylight preset](https://developer.apple.com/documentation/avfoundation/avcapturedevice/whitebalancetemperatureandtintvalues/daylight)
- [isGlobalToneMappingEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isglobaltonemappingenabled) · [automaticallyAdjustsVideoHDREnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/automaticallyadjustsvideohdrenabled) · [isVideoHDREnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvideohdrenabled)
- [Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- Core Video: [kCVPixelFormatType_14Bayer_RGGB](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_rggb) · [_GRBG](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_grbg) · [_BGGR](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_bggr) · [_GBRG](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_14bayer_gbrg) · [kCVPixelFormatType_64RGBALE](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_64rgbale) · [Pixel format identifiers](https://developer.apple.com/documentation/corevideo/1563591-pixel_format_identifiers)
- ImageIO: [DNG image properties](https://developer.apple.com/documentation/imageio/dng-image-properties) · [kCGImagePropertyDNGAsShotNeutral](https://developer.apple.com/documentation/imageio/kcgimagepropertydngasshotneutral) · [kCGImagePropertyExifExposureTime](https://developer.apple.com/documentation/imageio/kcgimagepropertyexifexposuretime) · [kCGImagePropertyExifISOSpeedRatings](https://developer.apple.com/documentation/imageio/kcgimagepropertyexifisospeedratings)
- Core Image: [CIRAWFilter.isLensCorrectionEnabled](https://developer.apple.com/documentation/coreimage/cirawfilter/islenscorrectionenabled)

### Apple WWDC sessions (P1)

- [WWDC16 session 501 — Advances in iOS Photography](https://developer.apple.com/videos/play/wwdc2016/501/) — original Bayer RAW session; preset/rear-camera/SIS constraints, DNG choice, four-char codes. **2016-era; treat specifics as potentially stale.**
- [WWDC16 session 511 — AVCapturePhotoOutput: Beyond the Basics](https://developer.apple.com/videos/play/wwdc2016/511/) — resource preparation for RAW and bracketed capture.
- [WWDC21 session 10160 — Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/) — **the single most load-bearing source**: Bayer-only-on-single-camera-devices, Linear DNG, ProRAW processing, `'l64r'`.
- [WWDC23 session 10105 — Create a more responsive camera experience](https://developer.apple.com/videos/play/wwdc2023/10105/) — zero shutter lag mechanism, default-on from iOS 17, exclusion list.
- [WWDC26 session 304 — Implement high resolution photo capture](https://developer.apple.com/videos/play/wwdc2026/304/) — current-era capture taxonomy, `maxPhotoDimensions` semantics, 24/48 MP preset constraint.

### Apple SDK headers (P1 text, mirror transport)

- `AVCapturePhotoOutput.h`, `iPhoneOS26.5.sdk` — the `-capturePhotoWithSettings:delegate:` rule block (Bayer RAW `.speed` and zoom==1.0 rules), `appleProRAWEnabled` ordering guarantee, bracket-settings restriction list, ZSL exclusions. <https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS26.5.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCapturePhotoOutput.h>
- `AVCaptureDevice.h`, `iPhoneOS26.5.sdk` — virtual-device feature exclusions, "RAW photo captures never have GDC applied", exposure/WB header discussions. <https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS26.5.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCaptureDevice.h>
- `CVPixelBuffer.h`, same SDK — Bayer four-char codes and bit-packing comments.

### Apple, non-developer-documentation (P2)

- [support.apple.com — Use Apple ProRAW](https://support.apple.com/en-us/119916) — the system Settings toggle; 48 MP restricted to main camera at 1x.
- [Apple Developer Forums thread 780406](https://developer.apple.com/forums/thread/780406) — Apple Staff Media Engineer on local tone mapping persisting under locked exposure.

### Corroboration only (C)

- [Lux — The Process Zero Manual](https://www.lux.camera/process-zero-manual/) — native Bayer RAW, 48 MP not exposed by iOS, no 2x lens on iPhone 15 Pro.
- [Lux — Introducing Process Zero](https://www.lux.camera/introducing-process-zero-for-iphone/)
- [Exiv2 issue 3041](https://github.com/Exiv2/exiv2/issues/3041) — one exiftool dump of an iPhone 16 Pro Max **ProRAW** DNG; `AsShotNeutral 1 1 1`, `BaselineExposure -2.35`.
- [Apple Developer Forums 66998](https://developer.apple.com/forums/thread/66998) and [689790](https://developer.apple.com/forums/thread/689790) — user reports of hidden exposure compensation and near-hardware WB adjustment. No Apple staff reply.

### Project-internal (measured, not Apple)

- [RAWForge#1 — map, locked constraints](https://github.com/tangericm/RAWForge/issues/1), inheriting photonforge [#2](https://github.com/tangericm/photonforge/issues/2), [#20](https://github.com/tangericm/photonforge/issues/20), [#22](https://github.com/tangericm/photonforge/issues/22).
