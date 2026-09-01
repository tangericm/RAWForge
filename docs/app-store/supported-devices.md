# Supported Devices

RAWForge requires iOS 17.0 or later and is built for iPhone.

Device support is determined dynamically, not from a promise that every iPhone model can capture Bayer RAW. At launch, RAWForge probes the physical rear cameras and their active capabilities. Capture is enabled only when the current iPhone exposes at least one usable physical camera with a supported Bayer RAW output and the controls required by the selected Recipe. RAWForge offers only sensors, exposure values, and firing behavior confirmed by that runtime probe; an unsupported sensor or Recipe is blocked rather than silently substituted.

Some iPhones, camera modules, formats, or OS combinations may not expose Bayer RAW or the required manual controls. On those devices RAWForge reports that no usable Bayer sensor is available. Composite or virtual multi-camera devices are not treated as proof that their constituent cameras support Bayer RAW. The iOS Simulator is suitable for interface and unit testing but cannot perform the physical Bayer RAW capture flow.

No external camera or accessory is required. A compatible physical iPhone is required for capture. App Review and release testing must include the dynamic capability check on each physical device used; the iOS 17 deployment floor alone does not imply Bayer RAW support.
