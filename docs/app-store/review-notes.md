# App Review Notes

RAWForge is a local Bayer RAW capture instrument. It has no account, sign-in, backend, analytics, advertising, in-app purchase, or network requirement. No external camera, mount, calibration target, or other accessory is required for the review flow below.

## Review device

Use a physical iPhone running iOS 17 or later. RAWForge probes the iPhone's camera capabilities at launch and enables capture only when at least one physical rear camera reports Bayer RAW support. The iOS Simulator does not provide Bayer RAW capture. If the viewfinder status says **No Bayer sensor**, please use a compatible physical iPhone.

## Reproducible starter Recipe capture

1. Launch RAWForge and allow Camera access. Wait for the on-device sensor probe to finish and the **Capture** tab to appear.
2. Aim the iPhone at an ordinary, well-lit scene. No external hardware or network connection is needed.
3. Tap **Plan** in the upper-right corner. In **Start a plan**, choose the **Single Frame** starter Recipe.
4. On the Recipe review screen, select any available sensor if a sensor picker is shown, then tap **Add 1-frame set to plan**. The current build stores the reviewed Recipe as a named protocol in the shot list.
5. Tap **Done** to return to Capture.
6. Tap **Open session**, then **Declare station**, then **Capture set 1 of 1**. If iOS asks for Motion access, either choice is valid: Motion evidence is optional and capture continues when it is denied or unavailable.
7. After the frame is banked, tap **Close station**.
8. Open the **Sessions** tab to inspect the completed session. The session detail provides the user-initiated export action through the iOS share sheet; swiping a session row exposes deletion.

The capture uses the built-in camera and writes a DNG plus its capture record to the app's local Documents directory. RAWForge does not upload the capture or diagnostic data.
