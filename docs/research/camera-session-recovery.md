# Camera-session resource exhaustion and recovery

Research for [RAWForge#33](https://github.com/tangericm/RAWForge/issues/33), 2026-09-01.
Primary sources are Apple Developer Documentation and the `iPhoneOS26.5.sdk`
headers installed with Xcode 26.6.

## Finding

The failure observed during repeated Device Characterisation runs is consistent
with camera-pipeline resource exhaustion, followed by a capture session that is
no longer running:

- The photo delegate returned `AVFoundationErrorDomain/-11803`, whose public SDK
  name is `AVErrorSessionNotRunning`. "Cannot Record" is only its localized
  presentation, not the enum case.
- The underlying error was `-16409`; after degradation, the system log emitted
  `FigXPCUtilities/-17281` and `FigCaptureSourceRemote` invalid-channel
  assertions. A later request could remain unresolved for 38 seconds.
- Thermal state stayed nominal and free storage stayed above 4 GB. Device
  Characterisation writes no files, so neither thermal shutdown nor disk
  exhaustion explains this sequence.
- A phone restart restored the complete 152-test hardware gate. That establishes
  camera-service state as the variable, not the #31 same-sensor fast path.

The exact private meaning of `-16409` and `-17281` is not published by Apple.
They must remain observations, not API contracts.

## Public contract

1. Apple names RAW and bracketed capture as operations that may need additional
   buffers or resources. It provides
   [`setPreparedPhotoSettingsArray`](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/setpreparedphotosettingsarray(_:completionhandler:))
   so this allocation happens before capture rather than lazily. Preparation is
   optional for API correctness, persists across session start/stop and committed
   configuration changes, and each call replaces the previous prepared array.
2. [`AVCaptureSession.runtimeErrorNotification`](https://developer.apple.com/documentation/avfoundation/avcapturesession/runtimeerrornotification)
   carries its `NSError` under `AVCaptureSessionErrorKey`.
3. [`AVCaptureSession.wasInterruptedNotification`](https://developer.apple.com/documentation/avfoundation/avcapturesession/wasinterruptednotification)
   carries an interruption reason and, for pressure interruptions, a system
   pressure state. The session may stop automatically during an interruption.
4. [`AVError.Code.mediaServicesWereReset`](https://developer.apple.com/documentation/avfoundation/averror-swift.struct/code/mediaserviceswerereset)
   specifically means media services were unavailable. Apple's AVCam sample
   restarts a previously running session for this code; it does not prescribe
   retrying every capture error.
5. The `AVCaptureSession.h` SDK header says `startRunning` blocks until startup
   succeeds or fails, and startup failures arrive through the runtime-error
   notification. The capture call itself is asynchronous, so a caller needs its
   own deadline if a broken service never completes the delegate sequence.

## Decision

RAWForge takes four bounded measures:

1. Prepare the union of RAW resource shapes used on the current physical sensor
   before capture. Replacing the sensor clears the local prepared-shape cache so
   the next request replaces settings for the old graph.
2. Record runtime errors, interruptions, interruption endings, starts and stops
   in the flight log, including every nested `NSError` domain/code plus session,
   pressure, thermal and storage state.
3. Give RAW resource preparation a 15-second deadline and each request a
   deadline of `max(15 seconds, summed exposures + 10 seconds)`. Late
   AVFoundation callbacks cannot resolve the continuation twice.
   A stopped or interrupted session also fails before RAW preparation, and every
   Bench setup checks that `startRunning` produced an available session before
   its duration can become profile data.
4. Device Characterisation uses four frames instead of the hardware maximum for
   its ordinary frame-period estimate. Its real seam measurement still exercises
   the maximum bracket, but only after resources are prepared. Because the Bench
   writes no scientific data, it may rebuild the local input/output graph and
   retry the whole run exactly once. A station never retries: silently repeating
   an unknown subset would invalidate the record.

If that one Bench recovery also fails, the UI reports that the camera did not
recover, points to the Console log, and recommends closing competing camera apps
and restarting the phone if the preview remains black. This is preferable to an
unbounded retry loop around an undocumented private-service failure.

## Hardware exit gate

- Three consecutive Release Device Characterisation runs from a fresh camera
  service, each producing a complete profile.
- Logs show RAW resource preparation before the first request and no unresolved
  capture, runtime error, or interruption.
- Immediately afterward, one single-frame Bayer capture and the complete device
  test suite pass without restarting the phone.
- If the failure occurs, preserve the log and verify the exactly-once rebuild and
  actionable terminal error rather than continuing to stress a degraded service.
