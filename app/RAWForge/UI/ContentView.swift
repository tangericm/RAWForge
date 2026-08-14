import SwiftUI

struct ContentView: View {
    @StateObject private var model = CaptureModel()

    /// Standard stops. Rails are validated against the sensor before anything
    /// fires, and a rung outside them is dropped and recorded, never clamped.
    private let shutters: [(String, Double)] = [
        ("1/2000", 1.0/2000), ("1/1000", 1.0/1000), ("1/500", 1.0/500),
        ("1/250", 1.0/250), ("1/125", 1.0/125), ("1/60", 1.0/60),
        ("1/30", 1.0/30), ("1/15", 1.0/15), ("1/8", 1.0/8),
        ("1/4", 1.0/4), ("1/2", 1.0/2), ("1s", 1.0),
    ]

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let report = model.report {
                    if report.canCapture { protocolSection(report); captureSection(report); setSection }
                    else { refusalSection }
                    if let station = model.lastStation { resultSection(station) }
                    ForEach(report.sensors) { SensorRow(sensor: $0) }
                    deviceSection(report.device)
                }
            }
            .navigationTitle("RAWForge")
            .toolbar {
                NavigationLink(destination: SessionBrowser()) { Text("Sessions") }
            }
            .task { await model.probe(); model.refreshProtocols() }
        }
    }

    private var statusSection: some View {
        Section {
            Text(model.status).font(.callout)
            if !model.progress.isEmpty {
                Text(model.progress).font(.caption).foregroundStyle(.secondary)
            }
            if let session = model.session {
                LabeledContent("Session", value: session.sessionId)
            } else if model.report?.canCapture == true {
                Button("Open session") { model.openSession() }
            }
            if model.busy { ProgressView() }
        }
    }

    /// Named, versioned protocols (#8). Authoring on device is a deliberate
    /// act, just a faster one than a desk trip — so the set can be built from
    /// the pickers below and then named, and the version bumps on every save.
    private func protocolSection(_ report: CapabilityReport) -> some View {
        Section("Protocol") {
            Picker("In force", selection: Binding(
                get: { model.selectedProtocol?.name ?? "" },
                set: { name in
                    model.selectedProtocol = name.isEmpty ? nil : ProtocolLibrary.load(named: name)
                    if !name.isEmpty { model.protocolName = name }
                })) {
                Text("authored here, unsaved").tag("")
                ForEach(model.savedProtocols, id: \.name) { p in
                    Text("\(p.name) v\(p.version)").tag(p.name)
                }
            }
            if let p = model.selectedProtocol {
                Text("\(p.name) v\(p.version) · \(p.specs.count) rungs · \(p.generator.describe)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("unsaved — the session will record the full definition either way, "
                     + "but an unnamed set cannot be re-run identically later")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                TextField("name", text: $model.protocolName).font(.callout)
                Button("Save") { model.saveProtocol() }
                    .disabled(model.protocolName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // One definition across sensors, shifted per sensor (#8). Useful ISO
            // ceilings differ enough that the same ladder may not suit all three.
            ForEach(report.usableSensors) { cap in
                let key = cap.sensor.rawValue
                Stepper(value: Binding(
                    get: { model.evOffsets[key] ?? 0 },
                    set: { model.evOffsets[key] = $0 == 0 ? nil : $0 }
                ), in: -3...3, step: 0.5) {
                    LabeledContent("\(key) EV offset",
                                   value: String(format: "%+.1f stop", model.evOffsets[key] ?? 0))
                }
            }
        }
    }

    private func captureSection(_ report: CapabilityReport) -> some View {
        Section("Capture set") {
            // A station is a pose and may span sensors (#7); pinning to one
            // is a shot list of length one, not a separate mode.
            ForEach(report.usableSensors) { cap in
                Toggle(cap.sensor.rawValue, isOn: Binding(
                    get: { model.selectedSensors.contains(cap.sensor) },
                    set: { on in
                        if on { model.selectedSensors.insert(cap.sensor) }
                        else { model.selectedSensors.remove(cap.sensor) }
                    }))
            }
            Picker("Execution", selection: $model.mode) {
                ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Sweep exposure", isOn: $model.isSweep)
            Stepper(value: $model.frameCount, in: 1...512) {
                LabeledContent("Frames", value: "\(model.frameCount)")
            }
            if model.isSweep {
                Stepper(value: $model.stopsPerRung, in: 0.25...3, step: 0.25) {
                    LabeledContent("Stops per rung", value: String(format: "%.2f", model.stopsPerRung))
                }
            }
            Picker(model.isSweep ? "Centre shutter" : "Shutter", selection: $model.requestedShutter) {
                ForEach(shutters, id: \.1) { Text($0.0).tag($0.1) }
            }
            if let cap = model.orderedSensors.compactMap(model.capability).first, let lo = cap.minISO, let hi = cap.maxISO {
                Stepper(value: $model.requestedISO, in: lo...hi, step: max(1, lo)) {
                    LabeledContent("ISO", value: String(format: "%.0f", model.requestedISO))
                }
            }
            ForEach(model.orderedSensors, id: \.self) { sensor in
                if let w = model.isoWarning(for: sensor) {
                    Text(w).font(.caption2).foregroundStyle(.orange)
                }
            }
            Stepper(value: $model.dwell, in: 0...5, step: 0.25) {
                LabeledContent("Dwell before first frame",
                               value: model.dwell == 0 ? "none" : String(format: "%.2fs", model.dwell))
            }
            Toggle("Authored sensor order", isOn: $model.useAuthoredSensorOrder)
            if model.useAuthoredSensorOrder {
                Text(model.orderedSensors.map(\.rawValue).joined(separator: " → "))
                    .font(.caption).monospaced()
                HStack {
                    ForEach(report.usableSensors) { cap in
                        Button(cap.sensor.rawValue) { model.appendToAuthoredOrder(cap.sensor) }
                            .buttonStyle(.bordered).font(.caption)
                    }
                }
                Text("tap in the order you want them shot")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Stepper(value: $model.minimumGap, in: 0...5, step: 0.25) {
                LabeledContent("Min inter-frame gap",
                               value: model.minimumGap == 0 ? "none" : String(format: "%.2fs", model.minimumGap))
            }
            // Presets plus free text. Two stations have already been mislabelled
            // — one typo that would split a condition under exact-string
            // grouping, one left blank entirely — and the label is the only
            // thing distinguishing conditions that differ solely in how the
            // phone was held.
            Picker("Pose", selection: $model.poseIntent) {
                Text("— unset —").tag("")
                ForEach(CaptureModel.poseIntentPresets, id: \.self) { Text($0).tag($0) }
                if !model.poseIntent.isEmpty
                    && !CaptureModel.poseIntentPresets.contains(model.poseIntent) {
                    Text(model.poseIntent).tag(model.poseIntent)
                }
            }
            TextField("or type one", text: $model.poseIntent)
                .font(.callout)
            if model.poseIntent.isEmpty {
                Text("unlabelled — a station with no pose intent cannot be told "
                     + "apart later from one held differently")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Button("Run station") { Task { await model.runStation() } }
                .disabled(model.session == nil || model.busy)
            Stepper(value: $model.darkRepeats, in: 1...32) {
                LabeledContent("Dark repeats", value: "\(model.darkRepeats)")
            }
            Button("Dark-frame calibration (#15) — cap the lens") {
                Task { await model.runDarkCalibration() }
            }
            .disabled(model.busy)
            if !model.darkProgress.isEmpty {
                Text(model.darkProgress).font(.caption2).foregroundStyle(.secondary)
            }
            Button("White-balance pixel probe (item 3)") { Task { await model.runWhiteBalanceProbe() } }
                .disabled(model.session == nil || model.busy)
            Button("Zoom enforcement probe (item 10)") { Task { await model.runZoomProbe() } }
                .disabled(model.session == nil || model.busy)
            if let z = model.zoomProbe {
                Text(z.verdict).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// The rendered set, shown before it runs — a sweep is a generator, and
    /// these are the rungs it actually produced.
    private var setSection: some View {
        Section("Rungs (\(model.currentSet.specs.count))") {
            Text(model.currentSet.generator.describe).font(.caption).foregroundStyle(.secondary)
            if let cap = model.orderedSensors.compactMap(model.capability).first {
                let checked = model.currentSet.validated(against: cap)
                ForEach(Array(checked.kept.prefix(12).enumerated()), id: \.offset) { i, s in
                    Text("\(i + 1). \(s.shutterLabel) · ISO \(Int(s.iso))").font(.caption).monospaced()
                }
                if checked.kept.count > 12 {
                    Text("… \(checked.kept.count - 12) more").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(checked.dropped.enumerated()), id: \.offset) { _, d in
                    Text("dropped: \(d.spec.shutterLabel) ISO \(Int(d.spec.iso)) — \(d.reason)")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.mode == .hardwareBracket, checked.kept.count > cap.maxBracketedCapturePhotoCount {
                    Text("\(checked.kept.count) exceeds this sensor's bracket max of "
                         + "\(cap.maxBracketedCapturePhotoCount) — use sequential")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func resultSection(_ station: StationRecord) -> some View {
        Section("Station \(station.stationIndex)") {
            // Surfaced, never acted on. Motion is a recorded observable and the
            // workstation decides what it means (#10, amended).
            if let m = station.motion {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.advisory.operatorNote)
                        .font(.caption).bold()
                        .foregroundStyle(m.advisory == .tripodLike ? .green
                                         : m.advisory == .elevated ? .orange : .red)
                    Text(String(format: "gyro p50 %.5f · p99 %.5f · max %.5f rad/s",
                                m.gyroP50, m.gyroP99, m.gyroMax))
                        .font(.caption2).monospaced()
                    Text("advisory only — no frames are discarded on motion")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(station.sensorSwaps.enumerated()), id: \.offset) { _, s in
                Text("\(s.fromSensor ?? "open") → \(s.toSensor): "
                     + String(format: "%.0f ms", s.durationSeconds * 1000))
                    .font(.caption).monospaced().foregroundStyle(.purple)
            }
            ForEach(Array(station.brackets.enumerated()), id: \.offset) { _, b in
                Text("\(b.sensor) · \(b.frames.count) frames · \(b.executionMode ?? "?")")
                    .font(.caption).bold()
                ForEach(Array(b.frames.enumerated()), id: \.offset) { _, f in
                    FrameRow(frame: f)
                }
            }
        }
    }

    private var refusalSection: some View {
        Section("Capture refused") {
            Text("Undemosaiced Bayer RAW is the only thing this app exists to produce. "
                 + "No sensor on this device offers it, so there is no instrument here.")
                .font(.footnote)
        }
    }

    private func deviceSection(_ device: DeviceIdentity) -> some View {
        Section("Device") {
            LabeledContent("Model", value: device.modelIdentifier)
            LabeledContent("OS", value: "\(device.systemName) \(device.systemVersion)")
            LabeledContent("App", value: "\(device.appVersion) (\(device.appBuild))")
            if device.isSimulator {
                Text("Simulator — no sensor exists here, and no session recorded "
                     + "on it is a calibration source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Capabilities are reflected, never judged (#6): every sensor is listed, and
/// the unusable ones name their specific shortfall rather than vanishing.
private struct SensorRow: View {
    let sensor: SensorCapability

    var body: some View {
        Section(header: header) {
            if let reason = sensor.exclusionReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if sensor.localizedName != nil {
                row("Bayer format", sensor.bayerFormatFourCC ?? "none")
                row("Max bracket count", "\(sensor.maxBracketedCapturePhotoCount)")
                row("Custom exposure", sensor.supportsCustomExposure ? "yes" : "no")
                row("WB gain lock", sensor.supportsWhiteBalanceCustomGainLock ? "yes" : "no")
                row("Max WB gain", String(format: "%.2f", sensor.maxWhiteBalanceGain))
                if let lo = sensor.minISO, let hi = sensor.maxISO {
                    row("ISO", String(format: "%.0f–%.0f", lo, hi))
                }
                if let lo = sensor.minExposureSeconds, let hi = sensor.maxExposureSeconds {
                    row("Exposure", String(format: "%.6fs–%.3fs", lo, hi))
                }
                if !sensor.zoomAssertionHeld {
                    row("⚠︎ minZoomFactor", String(format: "%.3f — documented as 1.0", sensor.minAvailableVideoZoomFactor))
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(sensor.sensor.rawValue)
            Spacer()
            Text(sensor.isUsable ? "Bayer" : "unavailable")
                .foregroundStyle(sensor.isUsable ? .green : .secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospaced().font(.caption) }
    }
}

/// The four witnesses, side by side. Requested, the device's read-back, the
/// photo's own EXIF and the written DNG are four distinct claims, and the
/// disagreement between them is the finding (#9).
private struct FrameRow: View {
    let frame: FrameRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            line("req", frame.requested.shutterSeconds)
            if let d = frame.deviceAchieved { line("dev", d.shutterSeconds) }
            if let p = frame.photoAchieved { line("exif", p.shutterSeconds) }
            if let v = frame.dng.exposureTimeSeconds { line("dng", v) }
            Text(frame.dng.uniqueCameraModel ?? "-")
                .font(.caption2).foregroundStyle(.secondary)
            if let g = frame.gapFromPreviousSeconds {
                Text(String(format: "gap %.1f ms", g * 1000))
                    .font(.caption2).monospaced().foregroundStyle(.blue)
            }
        }
    }

    private func line(_ label: String, _ seconds: Double) -> some View {
        Text(String(format: "%-4@ %.6fs", label as NSString, seconds))
            .font(.caption2).monospaced()
    }
}
