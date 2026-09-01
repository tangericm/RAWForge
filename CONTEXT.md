# RAWForge capture domain

This glossary defines the language presented to people using RAWForge. The file-format
names in older records remain valid, but new interface copy and product documentation use
the terms below consistently.

## Recipe

A named, versioned, reusable definition of a complete capture. A Recipe contains one or
more ordered Steps and answers: “What will happen when I press Capture?”

Avoid using **Plan**, **Protocol**, or **Shot list** for this concept in the interface.

## Recipe draft

An editable working copy of a Recipe. Saving a draft creates a new Recipe version; it does
not alter the definition embedded in an earlier Take.

## Step

One sensor-specific operation within a Recipe. A Step specifies its sensor, exposure
series, firing method, and any applicable timing controls.

Avoid using **Set** or **Shot-list entry** for this concept in the interface.

## Exposure Series

The frames requested by one Step. Its shape is **Single**, **Repeat**, or **Exposure
ladder**. Exact shutter and ISO values remain inspectable.

## Firing

How an Exposure Series reaches the camera: **Burst** or **Sequential**.

Avoid using **Execution mode** in the interface.

## Burst

Frames issued in hardware-sized requests and captured as quickly as the camera permits.
Long series may span several requests but remain Burst. Burst does not expose an authored
inter-frame gap.

Avoid using **Hardware bracket** in the interface.

## Sequential

Frames requested individually. The camera can be reconfigured and read back between
frames, and the Step may include an authored inter-frame gap.

## Run

A durable group of Takes used for browsing, transfer, and deletion. RAWForge creates or
resumes the active Run automatically when Capture is pressed.

Avoid using **Session** for this concept in the interface.

## Take

One atomic execution of a complete Recipe at one Pose. A Take is either banked completely
or absent; a failed or cancelled Take never appears as a successful partial result.

Avoid using **Station** for this concept in the interface.

## Pose

The intended relationship between phone and subject during a Take. A Pose may include an
optional operator label, but naming it is not required before capture.

## Frame

One DNG plus its requested settings, achieved readings, timing, focus, motion, clipping,
and provenance metadata.

## Witness

Recorded evidence about what happened during capture, such as achieved exposure, focus,
motion, clipping, timing, device state, or a dropped exposure rung.

## Device profile

The measured or borrowed capabilities and timing characteristics RAWForge uses to validate
and estimate a Recipe on the current iPhone.

## Calibration

A deliberate measurement used to interpret later captures, such as a dark calibration.
Calibration is supporting evidence, not a prerequisite for opening the camera.
