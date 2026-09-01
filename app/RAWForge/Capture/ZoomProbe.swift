#if DEBUG
import AVFoundation
import Foundation

/// #14 item 10: confirm that a Bayer RAW capture at `videoZoomFactor != 1.0`
/// **refuses** rather than silently degrading.
///
/// This matters beyond curiosity. #8 requires 2x to be *unreachable* rather
/// than merely undocumented, because 2x on this phone is the main sensor
/// cropped and cannot be captured in RAW at all. If the platform silently
/// serves a cropped or resampled frame instead of refusing, the app has to
/// enforce the boundary itself; if it throws, the platform enforces it and the
/// app only has to not ask.
struct ZoomProbeResult: Codable, Equatable {
    let sensor: String
    let requestedZoom: Double
    /// What the device reported after the set — a clamp shows up here.
    let zoomAfterSet: Double
    let minAvailableZoom: Double
    let maxAvailableZoom: Double

    let captureSucceeded: Bool
    let errorDescription: String?

    /// Present only if the capture succeeded. A frame that still measures the
    /// full sensor width is evidence the zoom was ignored rather than applied.
    let dngStoredWidth: Int?
    let dngActiveArea: [Int]?
    let dngUniqueCameraModel: String?

    /// Plain-language reading of the three outcomes this probe distinguishes.
    let verdict: String
}

extension CaptureRig {

    /// Sets a zoom factor, attempts one Bayer capture, and restores 1.0.
    /// Never throws: every outcome is a result, including the refusal.
    /// `stage` is called before and after each step and is expected to persist
    /// immediately. AVFoundation signals an illegal RAW configuration with an
    /// ObjC exception, which Swift cannot catch — so if this probe dies, the
    /// last stage written to disk *is* the result.
    func probeZoomEnforcement(requesting zoom: Double = 2.0,
                              stage: (String) -> Void = { _ in }) async -> ZoomProbeResult {
        guard let d = device, let sensor else {
            return ZoomProbeResult(
                sensor: "?", requestedZoom: zoom, zoomAfterSet: 0,
                minAvailableZoom: 0, maxAvailableZoom: 0, captureSucceeded: false,
                errorDescription: "rig not configured", dngStoredWidth: nil,
                dngActiveArea: nil, dngUniqueCameraModel: nil,
                verdict: "not run")
        }

        stage("configured")
        let minZoom = Double(d.minAvailableVideoZoomFactor)
        let maxZoom = Double(d.maxAvailableVideoZoomFactor)
        var applied = Double(d.videoZoomFactor)

        stage("about-to-set-zoom")
        if let _ = try? d.lockForConfiguration() {
            d.videoZoomFactor = CGFloat(min(max(zoom, minZoom), maxZoom))
            applied = Double(d.videoZoomFactor)
            d.unlockForConfiguration()
        }
        stage("zoom-set-to-\(applied)")

        var succeeded = false
        var errorText: String?
        var width: Int?
        var area: [Int]?
        var model: String?

        stage("about-to-capture-at-zoom-\(applied)")
        do {
            let photo = try await captureSingle()
            stage("capture-returned")
            succeeded = true
            if let data = photo.fileDataRepresentation() {
                let witness = DNGMetadata.read(data)
                width = witness.storedImageWidth
                area = witness.activeArea
                model = witness.uniqueCameraModel
            }
        } catch {
            errorText = "\(error)"
            stage("capture-threw")
        }

        // Always restore, so a probe cannot leave the rig zoomed for a real
        // capture that follows it.
        if let _ = try? d.lockForConfiguration() {
            d.videoZoomFactor = 1.0
            d.unlockForConfiguration()
        }
        stage("restored")

        let verdict: String
        if applied == 1.0 {
            verdict = "zoom could not be set away from 1.0 — the platform pins it, "
                + "so 2x is unreachable by construction"
        } else if !succeeded {
            verdict = "capture REFUSED at zoom \(applied) — the platform enforces the boundary"
        } else if let w = width, w >= 4224 {
            verdict = "capture SUCCEEDED at zoom \(applied) but the frame is still full width "
                + "(\(w)) — the zoom was ignored, not applied, so the payload is not cropped"
        } else {
            verdict = "capture SUCCEEDED at zoom \(applied) and the frame is \(width.map(String.init) ?? "?") wide "
                + "— SILENT DEGRADATION, the app must enforce zoom == 1.0 itself"
        }

        return ZoomProbeResult(
            sensor: sensor.rawValue, requestedZoom: zoom, zoomAfterSet: applied,
            minAvailableZoom: minZoom, maxAvailableZoom: maxZoom,
            captureSucceeded: succeeded, errorDescription: errorText,
            dngStoredWidth: width, dngActiveArea: area, dngUniqueCameraModel: model,
            verdict: verdict)
    }
}
#endif
