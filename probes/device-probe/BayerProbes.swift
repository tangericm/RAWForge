import AVFoundation
import CoreMedia
import ImageIO
import Foundation

/// Items 1, 3 and 14. Each writes its findings to the shared log and saves any
/// DNGs to Documents for off-device inspection.
@MainActor
struct BayerProbes {
    let rig: CaptureRig
    let log: ProbeLog

    /// Bring the camera up once, report what it can do, leave the session running.
    func prepare() async -> Bool {
        do {
            let granted = await requestCamera()
            guard granted else { log.log("camera permission denied — nothing to probe"); return false }
            try rig.configure()
            rig.startSession()
            log.log(rig.capabilityLine())
            return true
        } catch {
            log.log("rig setup failed: \(error)")
            return false
        }
    }

    // MARK: item 1 — can a Bayer RAW bracket be captured at all?

    func probeBracketFeasibility() async {
        log.section("Item 1 — Bayer RAW bracket feasibility")
        let f = rig.device?.activeFormat
        let iso = f?.minISO ?? 100
        // Three stops apart, well inside the rails: 1/500, 1/125, 1/30-ish.
        let durations = [
            CMTime(value: 1, timescale: 500),
            CMTime(value: 1, timescale: 125),
            CMTime(value: 1, timescale: 30)
        ]
        log.log("requesting a \(durations.count)-frame manual-exposure Bayer bracket at ISO \(iso)")
        do {
            let photos = try await rig.captureBracket(durations: durations, iso: iso)
            log.log("SUCCESS — delivered \(photos.count) of \(durations.count) frames")
            log.log("→ the feared photoQualityPrioritization/bracket conflict does NOT block a Bayer bracket")
            for (i, p) in photos.enumerated() {
                if let data = p.fileDataRepresentation() {
                    let name = "item1_bracket_f\(i).dng"
                    save(data, name)
                }
            }
        } catch {
            log.log("FAILED — \(error)")
            log.log("→ record the exact error on #14; a failure here reshapes the bracket model")
        }
    }

    // MARK: item 3 — does a locked WB reach the pixels, or only the metadata?

    func probeWhiteBalancePath() async {
        log.section("Item 3 — white-balance pixel path")
        log.log("Fixed scene + fixed light assumed. Two locked gains, one frame each.")
        // A single mid exposure so only WB differs between the two frames.
        let iso = rig.device?.activeFormat.minISO ?? 100
        do {
            try await rig.lockExposure(duration: CMTime(value: 1, timescale: 125), iso: iso)

            let warm = try await rig.lockWhiteBalance(r: 3.0, g: 1.0, b: 1.0)
            log.log("locked WARM gains r/g/b = \(warm.redGain)/\(warm.greenGain)/\(warm.blueGain)")
            try await captureAndReport(name: "item3_warm.dng", tagLabel: "WARM AsShotNeutral")

            let cool = try await rig.lockWhiteBalance(r: 1.0, g: 1.0, b: 3.0)
            log.log("locked COOL gains r/g/b = \(cool.redGain)/\(cool.greenGain)/\(cool.blueGain)")
            try await captureAndReport(name: "item3_cool.dng", tagLabel: "COOL AsShotNeutral")

            log.log("METADATA LIMB: compare the two AsShotNeutral lines above.")
            log.log("PIXEL LIMB: pull item3_warm.dng and item3_cool.dng to the Mac and compare")
            log.log("  raw Bayer values of a neutral patch. If the pixels differ, the gains reached")
            log.log("  the sensor data and the 'pin WB to Daylight' constraint needs qualifying.")
        } catch {
            log.log("FAILED — \(error)")
        }
    }

    // MARK: item 14 — is the Bayer path noise-reduction-free?

    func probeNoiseReduction() async {
        log.section("Item 14 — NoiseReductionApplied on the Bayer path")
        let iso = rig.device?.activeFormat.minISO ?? 100
        do {
            try await rig.lockExposure(duration: CMTime(value: 1, timescale: 125), iso: iso)
            let photos = try await rig.captureSingle()
            guard let data = photos.first?.fileDataRepresentation() else {
                log.log("no DNG data returned"); return
            }
            save(data, "item14_bayer.dng")
            log.log("DNG metadata:")
            log.log(DNGInspector.report(data))
            log.log("→ 0/0 or <absent> means UNKNOWN per the DNG spec, not zero. State it that way.")
        } catch {
            log.log("FAILED — \(error)")
        }
    }

    // MARK: helpers

    private func captureAndReport(name: String, tagLabel: String) async throws {
        let photos = try await rig.captureSingle()
        guard let data = photos.first?.fileDataRepresentation() else {
            log.log("  \(tagLabel): <no DNG data>"); return
        }
        save(data, name)
        // Pull just the one line the metadata limb needs; the full dump is item 14's job.
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] {
            log.log("  \(tagLabel): \(dng[kCGImagePropertyDNGAsShotNeutral] ?? "<absent>")")
        } else {
            log.log("  \(tagLabel): <could not read>")
        }
    }

    private func save(_ data: Data, _ name: String) {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        do {
            try data.write(to: url)
            log.log("  saved \(name) (\(data.count / 1024) KB) → Documents")
        } catch {
            log.log("  save \(name) FAILED — \(error)")
        }
    }

    private func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}
