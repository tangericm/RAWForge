import AVFoundation
import ImageIO
import Foundation

/// Carries which rung failed and how many had already landed. A station still
/// aborts and deletes, while the log retains the exact point of failure.
struct SequenceFault: Error {
    let sensor: String
    let frameIndex: Int
    let completed: Int
    let underlying: Error
}

/// The AVFoundation implementation of the station's capture seam.
@MainActor
final class LiveStationCapture: StationCapturing {
    private let rig: CaptureRig
    private let motion: MotionRecorder

    init(rig: CaptureRig, motion: MotionRecorder) {
        self.rig = rig
        self.motion = motion
    }

    func prepareForFraming(_ sensor: SensorCapability.Sensor) {
        rig.prepareForFraming(sensor)
    }

    func configure(_ sensor: SensorCapability.Sensor) async throws {
        try await rig.configure(sensor)
        await rig.startSessionAndWait()
    }

    func lockWhiteBalance() async throws -> StationWhiteBalance {
        let gains = try await rig.lockWhiteBalance()
        return StationWhiteBalance(set: gains.set, readBack: gains.readBack)
    }

    func applyFocus(_ resolution: FocusResolution) async -> FrameRecord.Focus {
        await rig.applyFocus(resolution)
    }

    func stop() { rig.stopSession() }

    func capture(_ request: StationCaptureRequest,
                 progress: @escaping (String) -> Void) async throws -> SetShot {
        var frames: [FrameRecord] = []
        var previousTimestamp: Double?
        var requestSizes: [Int]?

        /// Written the moment it arrives, then the photo is released. A
        /// 336-frame dark mirror could never hold its photos in memory.
        func bank(_ photo: AVCapturePhoto, _ spec: CaptureSpec,
                  device: FrameRecord.Exposure?) throws {
            let index = frames.count + 1
            guard let data = photo.fileDataRepresentation() else {
                logError(.capture, "frame \(index) on \(request.sensor.rawValue): "
                         + "fileDataRepresentation() returned nil — the photo arrived but carries no file")
                throw CaptureRig.RigError.captureFailed(
                    "frame \(index): fileDataRepresentation() returned nil")
            }
            let filename = SessionStore.frameFilename(
                sessionId: request.session.sessionId,
                station: request.stationIndex,
                bracket: request.bracketIndex,
                frame: index,
                sensor: request.sensor.rawValue)
            do {
                _ = try SessionStore.writeFrame(
                    data, named: filename, sessionId: request.session.sessionId)
            } catch {
                logFailure(.store, "writing \(filename) (\(data.count / 1_000_000) MB)", error)
                throw error
            }

            DeviceProfile.noteObservedFrame(bytes: data.count)

            let witness = DNGMetadata.read(data)
            let clip = ClippingStats.compute(
                from: photo, bayerFormat: rig.bayerFormat,
                activeArea: witness.activeArea,
                blackLevel: witness.blackLevel?.first,
                whiteLevel: witness.whiteLevel?.first)
            logTrace(.capture, String(format: "frame %d/%d %@ · %.1f MB · asked %.6fs ISO %.0f, "
                                      + "DNG says %.6fs ISO %d",
                                      index, request.specs.count, filename,
                                      Double(data.count) / 1_000_000,
                                      spec.shutterSeconds, spec.iso,
                                      witness.exposureTimeSeconds ?? 0, witness.iso ?? 0))
            if let reason = clip.unavailableReason {
                logWarn(.capture, "frame \(index): no clipping statistics — \(reason)")
            }

            let stamp = photo.timestamp.isValid ? photo.timestamp.seconds : nil
            let rawCapturedUptime = ProcessInfo.processInfo.systemUptime
            let rawDeliveryUptime = ProcessInfo.processInfo.systemUptime
            let exposureWindow = stamp.map { ($0, $0 + spec.shutterSeconds) }
            let neighbourhood = stamp.map { ($0 - 0.1, $0 + spec.shutterSeconds + 0.1) }
            frames.append(FrameRecord(
                frameIndex: index,
                filename: filename,
                sensor: request.sensor.rawValue,
                requested: FrameRecord.Exposure(
                    shutterSeconds: spec.shutterSeconds,
                    iso: spec.iso,
                    whiteBalanceGains: request.whiteBalance.set),
                deviceAchieved: device,
                photoAchieved: Self.exposure(from: photo, wb: request.whiteBalance.readBack),
                dng: witness,
                focus: request.focus,
                zoomFactor: rig.currentZoomFactor,
                capturedAtSegmentStartSeconds: request.timebase.secondsSinceOrigin(
                    rawCapturedUptime),
                capturedAt: Date(),
                photoTimestampAtSegmentStartSeconds: request.timebase.secondsSinceOrigin(stamp),
                gapFromPreviousSeconds: pair(stamp, previousTimestamp).map { $0 - $1 },
                clipping: clip,
                motion: exposureWindow.flatMap { motion.summary(from: $0.0, to: $0.1) }
                    .map { $0.offsettingWindow(by: -request.timebase.originUptime) },
                motionNeighbourhood: neighbourhood.flatMap {
                    motion.summary(from: $0.0, to: $0.1)
                }.map { $0.offsettingWindow(by: -request.timebase.originUptime) },
                deliveredAtSegmentStartSeconds: request.timebase.secondsSinceOrigin(
                    rawDeliveryUptime),
                latestMotionAtSegmentStartSeconds: motion.latestTimestamp()))
            previousTimestamp = stamp ?? previousTimestamp
        }

        switch request.firing {
        case .sequential:
            var lastFired: TimeInterval?
            for (index, spec) in request.specs.enumerated() {
                progress("\(request.sensor.rawValue) sequential \(index + 1)/"
                         + "\(request.specs.count) — \(spec.shutterLabel)")
                do {
                    let achieved = try await rig.lockExposure(
                        shutterSeconds: spec.shutterSeconds, iso: spec.iso)
                    if let lastFired, request.minimumGap > 0 {
                        let elapsed = ProcessInfo.processInfo.systemUptime - lastFired
                        if elapsed < request.minimumGap {
                            try? await Task.sleep(nanoseconds: UInt64(
                                (request.minimumGap - elapsed) * 1_000_000_000))
                        }
                    }
                    lastFired = ProcessInfo.processInfo.systemUptime
                    try bank(try await rig.captureSingle(), spec, device: achieved)
                } catch {
                    throw SequenceFault(sensor: request.sensor.rawValue,
                                        frameIndex: index + 1,
                                        completed: frames.count,
                                        underlying: error)
                }
            }

        case .hardwareBracket:
            progress("\(request.sensor.rawValue) bracket of \(request.specs.count)")
            do {
                requestSizes = try await rig.captureBracket(request.specs) { photo, spec in
                    try bank(photo, spec, device: nil)
                }
            } catch {
                throw SequenceFault(sensor: request.sensor.rawValue,
                                    frameIndex: frames.count + 1,
                                    completed: frames.count,
                                    underlying: error)
            }
        }
        return SetShot(frames: frames, bracketRequestSizes: requestSizes)
    }

    static func exposure(from photo: AVCapturePhoto,
                         wb: [Float]) -> FrameRecord.Exposure? {
        guard let exif = photo.metadata[
            kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return nil
        }
        return FrameRecord.Exposure(
            shutterSeconds: exif[kCGImagePropertyExifExposureTime as String] as? Double ?? 0,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?
                .first?.floatValue ?? 0,
            whiteBalanceGains: wb)
    }
}

final class LiveStationPersistence: StationPersisting {
    func open(capability: CapabilityReport) throws -> SessionRecord {
        try SessionStore.open(
            capability: capability,
            calibration: SessionStore.latestCalibration())
    }

    func hasRoom(forFrames count: Int) -> Bool {
        SessionStore.hasRoom(forFrames: count)
    }

    func writeMotionStream(_ samples: [MotionSample], sessionId: String,
                           station: Int) throws -> String {
        try SessionStore.writeMotionStream(samples, sessionId: sessionId, station: station)
    }

    func writeStation(_ station: StationRecord) throws {
        try SessionStore.writeStation(station)
    }

    func deleteStationFrames(sessionId: String, station: Int) {
        SessionStore.deleteStationFrames(sessionId: sessionId, station: station)
    }
}

extension MotionRecorder: StationMotionRecording {}
extension DeviceHealth: StationHealthChecking {}

private func pair<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
