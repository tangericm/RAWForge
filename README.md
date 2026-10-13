# RAWForge

An iPhone app for repeatable RAW capture. Create an exposure recipe, capture the same sequence at each position, and export DNG files with the settings and motion records beside them.

Built with Swift and SwiftUI. Captures stay on your iPhone until you choose to export them; no account or cloud service is required.

**Status:** In development. Public release work is tracked in the [App Store roadmap](https://github.com/tangericm/RAWForge/issues/16). Install from source using the steps below.

## What it includes

- **Exposure recipes:** choose cameras, shutter speeds, ISO values and repeated frames, with Burst or Sequential capture.
- **Shoot:** live preview, focus controls, and estimated capture time and storage.
- **Runs and Takes:** repeat a Recipe at different positions, keeping each capture's settings and optional device motion together.
- **Library and export:** review saved Runs and share an archive containing DNGs, the Recipe and capture records. Files are also accessible through the iOS Files app or a cable.

## Install from source

Requires a Mac with Xcode and its iOS platform installed, Homebrew, and an Apple account for signing. Capture requires a compatible physical iPhone running **iOS 17 or later**. RAWForge checks which cameras support Bayer RAW; see [supported devices](docs/app-store/supported-devices.md).

```bash
brew install xcodegen
git clone https://github.com/tangericm/RAWForge.git
cd RAWForge/app
xcodegen generate
open RAWForge.xcodeproj
```

1. In Xcode, select the **RAWForge** scheme and your connected iPhone.
2. Open the app target's **Signing & Capabilities**, enable automatic signing and select your team. If the bundle identifier is unavailable, change it to a unique identifier.
3. Follow Xcode's device-pairing and Developer Mode prompts, then click **Run**. Allow camera access when the app asks. Motion access is optional.

The Xcode project is generated from `app/project.yml`. The iOS Simulator can be used for interface testing, but cannot capture real RAW frames.

## Use it

1. In **Library**, select a Recipe or create one with **New Recipe**.
2. In **Shoot**, check the preview and focus, then tap **Capture**. A Run starts automatically, and the Recipe's Steps form one Take at the current position.
3. Move to the next position and tap **Capture** again. Choose **Run → Finish Run** when done; earlier captures stay saved.
4. Open **Library → Captured Runs**, choose a Run and tap the share button to export it.

## What the sensors actually do

For sensor limits, measured capture behavior and API notes, see the [capture findings](docs/capture-findings.md). Measurements there are specific to the tested iPhone 15 Pro.

## More information

- [Privacy policy](docs/app-store/privacy-policy.md)
- [Development and testing](docs/ci.md)
- [Report an issue](https://github.com/tangericm/RAWForge/issues)
- [Earlier Python RAW pipeline](https://github.com/tangericm/RAWForge/tree/isp-pipeline)

## License

[Apache-2.0](LICENSE).
