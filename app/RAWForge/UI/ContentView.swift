import SwiftUI

/// Four screens: the instrument, the record, the flight recorder, and the bench.
///
/// The capture flow is the app. The bench is how the instrument is checked
/// rather than how it is used, and the console is how a failure in either is
/// read at the pose instead of on a laptop an hour later.
struct ContentView: View {
    @StateObject private var model = CaptureModel()
    @State private var booted = false

    var body: some View {
        Group {
            if model.cameraDenied {
                CameraDeniedView()
            } else if !booted {
                BootingView()
            } else {
                tabs
            }
        }
        .task {
            // Frames whose station never closed belong to a station that never
            // existed. Swept before anything reads the directory.
            let orphans = SessionStore.sweepOrphanedFrames()
            if orphans > 0 {
                logWarn(.store, "swept \(orphans) orphaned frame(s) from a station that never closed")
            }
            await model.probe()
            model.refreshProtocols()
            model.restoreShotList()
            if orphans > 0 {
                model.status = "swept \(orphans) orphaned frame(s) from an unclosed station"
            }
            booted = true
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack { CaptureFlowView(model: model, showConsole: { tab = 2 }) }
                .tabItem { Label("Capture", systemImage: "camera.aperture") }.tag(0)
            NavigationStack { SessionBrowser() }
                .tabItem { Label("Sessions", systemImage: "folder") }.tag(1)
            NavigationStack { LogConsoleView() }
                .tabItem { Label("Console", systemImage: "text.alignleft") }.tag(2)
            NavigationStack { BenchView(model: model) }
                .tabItem { Label("Bench", systemImage: "wrench.and.screwdriver") }.tag(3)
        }
    }

    /// Debug builds can be launched straight onto a tab, which is how these
    /// screens get looked at on a simulator — it has no camera, so the capture
    /// screen never leaves its refusal state and nothing else is reachable.
    ///
    ///     SIMCTL_CHILD_RAWFORGE_START_TAB=2 xcrun simctl launch <sim> com.tangericm.rawforge
    @State private var tab: Int = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["RAWFORGE_START_TAB"],
           let requested = Int(raw), (0...3).contains(requested) {
            return requested
        }
        #endif
        return 0
    }()
}

/// The probe walks three sensors and takes a moment. Better than an empty
/// screen that looks broken.
private struct BootingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            ProgressView()
            Text("Probing sensors…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Without the camera there is no instrument, so this is the whole app rather
/// than a banner on it.
private struct CameraDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Camera access is off", systemImage: "camera.slash")
        } description: {
            Text("RAWForge cannot probe a sensor, let alone capture one, without it. "
                 + "Nothing else in the app will work until it is granted.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// The bench: what this device is, and the runs that check the instrument
/// rather than use it.
struct BenchView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        List {
            // Suppressed when there is no instrument: the refusal section below
            // says the same thing at length, and a screen that opens by stating
            // its one fact twice reads as unfinished.
            if model.report?.canCapture == true && !model.status.isEmpty {
                Section {
                    Text(model.status).font(.callout)
                    if !model.progress.isEmpty {
                        Text(model.progress).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.busy { ProgressView() }
                }
            }

            if let report = model.report {
                Section {
                    NavigationLink {
                        CalibrationView(model: model)
                    } label: {
                        Label("Dark-frame calibration", systemImage: "moon.stars")
                    }
                    NavigationLink {
                        InstrumentChecksView(model: model)
                    } label: {
                        Label("Instrument checks", systemImage: "checklist")
                    }
                    if let station = model.lastStation {
                        NavigationLink {
                            LastStationView(station: station)
                        } label: {
                            Label("Last station · \(station.stationIndex)",
                                  systemImage: "doc.text.magnifyingglass")
                        }
                    }
                } header: {
                    Text("Runs")
                } footer: {
                    Text("These check the instrument. They are not how it is used — "
                         + "a scene is shot from the Capture screen.")
                }

                if !report.canCapture { refusalSection }
                Section("Sensors") {
                    ForEach(report.sensors) { SensorSummaryRow(sensor: $0) }
                }
                deviceSection(report.device)
            }
        }
        .navigationTitle("Bench")
    }

    private var refusalSection: some View {
        Section {
            Label {
                Text("Undemosaiced Bayer RAW is the only thing this app exists to produce. "
                     + "No sensor on this device offers it, so there is no instrument here.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } header: {
            Text("Capture refused")
        }
    }

    private func deviceSection(_ device: DeviceIdentity) -> some View {
        Section("Device") {
            LabeledContent("Model", value: device.modelIdentifier)
            LabeledContent("OS", value: "\(device.systemName) \(device.systemVersion)")
            LabeledContent("App", value: "\(device.appVersion) (\(device.appBuild))")
            LabeledContent("Health", value: model.health.summary)
            if let free = SessionStore.availableCapacityBytes() {
                LabeledContent("Free space", value: SessionEstimate.formatBytes(free))
            }
            if device.isSimulator {
                Label("Simulator — no sensor exists here, and no session recorded on it "
                      + "is a calibration source.", systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Capabilities are reflected, never judged (#6): every sensor is listed, and
/// the unusable ones name their specific shortfall rather than vanishing.
private struct SensorSummaryRow: View {
    let sensor: SensorCapability

    var body: some View {
        NavigationLink {
            SensorDetailView(sensor: sensor)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sensor.sensor.rawValue).font(.callout)
                    Text(sensor.isUsable
                         ? "\(sensor.bayerFormatFourCC ?? "Bayer") · bracket ≤ \(sensor.maxBracketedCapturePhotoCount)"
                         : sensor.exclusionReason ?? "unavailable")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: sensor.isUsable ? "checkmark.circle.fill" : "slash.circle")
                    .foregroundStyle(sensor.isUsable ? .green : .secondary)
            }
        }
    }
}

private struct SensorDetailView: View {
    let sensor: SensorCapability

    var body: some View {
        List {
            if let reason = sensor.exclusionReason {
                Section {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Why it is excluded")
                }
            }
            if sensor.localizedName != nil {
                Section("Measured") {
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
                }
                if !sensor.zoomAssertionHeld {
                    Section {
                        Label(String(format: "minAvailableVideoZoomFactor is %.3f, not the "
                                     + "documented 1.0.", sensor.minAvailableVideoZoomFactor),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle(sensor.sensor.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospaced().font(.caption) }
    }
}

/// The station just shot, in full. Kept out of the capture screen because it is
/// read after the fact, not at the pose.
private struct LastStationView: View {
    let station: StationRecord

    var body: some View {
        List {
            // Surfaced, never acted on. Motion is a recorded observable and the
            // workstation decides what it means (#10, amended).
            if let m = station.motion {
                Section("Motion") {
                    Text(m.advisory.operatorNote)
                        .font(.callout).bold()
                        .foregroundStyle(m.advisory == .tripodLike ? .green
                                         : m.advisory == .elevated ? .orange : .red)
                    Text(String(format: "gyro p50 %.5f · p99 %.5f · max %.5f rad/s",
                                m.gyroP50, m.gyroP99, m.gyroMax))
                        .font(.caption2).monospaced()
                    Text("Advisory only — no frames are discarded on motion.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !station.sensorSwaps.isEmpty {
                Section("Sensor swaps") {
                    ForEach(Array(station.sensorSwaps.enumerated()), id: \.offset) { _, s in
                        Text("\(s.fromSensor ?? "open") → \(s.toSensor): "
                             + String(format: "%.0f ms", s.durationSeconds * 1000))
                            .font(.caption).monospaced()
                    }
                }
            }
            ForEach(Array(station.brackets.enumerated()), id: \.offset) { _, b in
                Section("\(b.sensor) · \(b.frames.count) frames · \(b.executionMode ?? "?")") {
                    ForEach(Array(b.frames.enumerated()), id: \.offset) { _, f in
                        FrameWitnessRow(frame: f)
                    }
                }
            }
        }
        .navigationTitle("Station \(station.stationIndex)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The four witnesses, side by side. Requested, the device's read-back, the
/// photo's own EXIF and the written DNG are four distinct claims, and the
/// disagreement between them is the finding (#9).
private struct FrameWitnessRow: View {
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
