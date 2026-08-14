import AVFoundation
import Foundation

/// The station flow's transitions, layered over the capture engine.
///
/// Each phase exists because something must finish before the next may start.
/// The waits are not prompts: there is no override on stillness and nothing
/// fires before the exposure has settled.
@MainActor
extension CaptureModel {

    var canDeclareStation: Bool { phase == .sessionOpen }
    var canBeginSet: Bool { phase == .stationOpen && shotList.current != nil }
    var canCloseStation: Bool { phase == .stationOpen && shotList.canClose }

    func startFlow() {
        phase = session == nil ? .noSession : .sessionOpen
        flowNote = phase.note
        startFraming()
    }

    /// Framing runs between stations, when the operator is walking to the next
    /// pose and needs to see where the camera points. Never touched mid-station:
    /// the capture path owns the session once a set begins.
    func startFraming() {
        guard !busy, phase == .sessionOpen || phase == .stationOpen else { return }
        let sensor = shotList.current?.sensor ?? builderSensor
        guard capability(sensor)?.isUsable == true else { return }
        rig.prepareForFraming(sensor)
    }

    /// Stations accumulate rather than being planned up front (#10), so this is
    /// an explicit act at the pose, not a slot filled in beforehand.
    func declareStation() {
        guard canDeclareStation else { return }
        health.refresh()
        if let fault = health.faultIfUnhealthy() {
            status = "not starting a station — \(fault.operatorNote)"
            return
        }
        stationIndex += 1
        stationOpenedAt = Date()
        pendingBrackets = []
        pendingSwaps = []
        lastFault = nil
        shotList.cursor = 0
        motionRecorder.start()
        set(.stationOpen)
    }

    /// Walks one shot-list entry through swap, still, settle and capture.
    func beginNextSet() async {
        guard canBeginSet, let entry = shotList.current,
              let session, let cap = capability(entry.sensor) else { return }

        // Faults land at a set boundary rather than halfway through a bracket.
        health.refresh()
        if let fault = health.faultIfUnhealthy() { abortStation(fault); return }
        if !SessionStore.hasRoom(forFrames: entry.frameCount) {
            abortStation(.storageExhausted); return
        }

        busy = true
        defer { busy = false }

        do {
            set(.swapping)
            let swapStart = ProcessInfo.processInfo.systemUptime
            try rig.configure(entry.sensor)
            rig.startSession()
            let swapEnd = ProcessInfo.processInfo.systemUptime
            pendingSwaps.append(StationRecord.SwapRecord(
                fromSensor: pendingSwaps.last?.toSensor, toSensor: entry.sensor.rawValue,
                durationSeconds: swapEnd - swapStart,
                motion: motionRecorder.summary(from: swapStart, to: swapEnd)))

            // A wait, not a prompt. It cannot be overridden, and it never
            // deletes anything — motion is an advisory (#10, amended), so this
            // resolves either when the device is still or when waiting longer
            // has stopped being informative.
            set(.stilling)
            await waitForStillness()

            set(.settling)
            let offset = entry.captureSet.perSensorEVOffsetStops[entry.sensor.rawValue] ?? 0
            let rendered = CaptureSet(
                name: entry.captureSet.name, version: entry.captureSet.version,
                specs: entry.captureSet.rendered(for: entry.sensor),
                generator: entry.captureSet.generator,
                perSensorEVOffsetStops: entry.captureSet.perSensorEVOffsetStops)
            let checked = rendered.validated(against: cap)
            guard !checked.kept.isEmpty else {
                throw CaptureRig.RigError.unsupported(
                    "every rung of \(entry.captureSet.name) is outside \(entry.sensor.rawValue)'s rails")
            }
            let wb = try await rig.lockWhiteBalance()

            set(.capturing)
            let frames = try await shoot(checked.kept, sensor: entry.sensor, wb: wb,
                                         session: session, station: stationIndex,
                                         bracketIndex: pendingBrackets.count + 1)
            pendingBrackets.append(BracketRecord(
                bracketIndex: pendingBrackets.count + 1, sensor: entry.sensor.rawValue,
                sensorUniqueID: cap.uniqueID, captureSet: entry.captureSet,
                renderedSpecs: checked.kept, evOffsetStops: offset,
                executionMode: mode.rawValue, droppedRungs: checked.dropped,
                minimumInterFrameGapSeconds: minimumGap > 0 ? minimumGap : nil,
                dwellSeconds: dwell > 0 ? dwell : nil, note: nil, frames: frames))

            rig.stopSession()
            shotList.cursor += 1
            set(.stationOpen)
            startFraming()
        } catch {
            rig.stopSession()
            abortStation(.captureError, detail: "\(error)")
        }
    }

    /// Nothing lands until the whole shot list is done.
    func closeStation() {
        guard canCloseStation, let session else { return }
        motionRecorder.stop()
        let samples = motionRecorder.snapshot()
        let streamFile = samples.isEmpty ? nil
            : try? SessionStore.writeMotionStream(samples, sessionId: session.sessionId, station: stationIndex)
        let record = StationRecord(
            stationIndex: stationIndex, sessionId: session.sessionId,
            openedAt: stationOpenedAt ?? Date(), closedAt: Date(),
            brackets: pendingBrackets, sensorSwaps: pendingSwaps,
            motion: samples.isEmpty ? nil : MotionSummary.over(
                samples, from: samples.first!.t, to: samples.last!.t),
            motionStreamFile: streamFile,
            motionRequestedHz: motionRecorder.requestedHz,
            poseIntent: poseIntent)
        do {
            try SessionStore.writeStation(record)
            lastStation = record
            status = "station \(stationIndex) banked — \(record.brackets.reduce(0) { $0 + $1.frames.count }) frames"
        } catch {
            status = "could not write station \(stationIndex) — \(error)"
        }
        pendingBrackets = []
        pendingSwaps = []
        set(.sessionOpen)
        startFraming()
    }

    /// One rule: a hard fault flags, aborts the station, and deletes its frames.
    /// Stations already banked survive.
    func abortStation(_ fault: StationFault, detail: String? = nil) {
        guard let session else { return }
        motionRecorder.stop()
        SessionStore.deleteStationFrames(sessionId: session.sessionId, station: stationIndex)
        pendingBrackets = []
        pendingSwaps = []
        lastFault = fault
        set(.sessionOpen)
        startFraming()
        status = "station \(stationIndex) ABORTED — \(fault.operatorNote)"
            + (detail.map { ": \($0)" } ?? "") + ". Frames deleted; banked stations survive."
    }

    func closeSession() {
        guard phase == .sessionOpen else { return }
        session = nil
        shotList.cursor = 0
        set(.noSession)
    }

    // MARK: - Waits

    /// Polls the live motion stream until the device settles into the tripod
    /// band, or until waiting longer stops being informative. There is no
    /// override, and there is no deletion either — this is a wait.
    private func waitForStillness(timeout: TimeInterval = 4.0) async {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            let now = ProcessInfo.processInfo.systemUptime
            if let m = motionRecorder.summary(from: now - 0.4, to: now),
               m.sampleCount > 8, m.advisory == .tripodLike {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func set(_ p: StationPhase) {
        phase = p
        flowNote = p.note
    }
}
