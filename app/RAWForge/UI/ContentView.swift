import SwiftUI

/// Four screens: the instrument, the record, the flight recorder, and the bench.
///
/// The capture flow is the app. The bench is how the instrument is checked
/// rather than how it is used, and the console is how a failure in either is
/// read at the pose instead of on a laptop an hour later.
struct ContentView: View {
    @ObservedObject var launchNoticeStore: LaunchNoticeStore
    @StateObject private var model = CaptureModel()
    @State private var booted = false
    @State private var showingHelpSettings = false

    var body: some View {
        Group {
            #if DEBUG
            // The timeline is two taps deep behind a shot list that a simulator
            // cannot build, so it would otherwise ship having only been
            // compiled and never seen.
            if DemoSeed.wantsStarterReview {
                NavigationStack {
                    StarterCaptureReview(model: model, starter: .exposureLadder)
                }
            } else if DemoSeed.wantsFocus {
                NavigationStack { FocusPreflightView(model: model) }
            } else if DemoSeed.wantsTimeline {
                NavigationStack {
                    List { StationPlanView(model: model) }
                        .navigationTitle("Timeline")
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if model.cameraDenied {
                CameraDeniedView()
            } else if !booted {
                BootingView()
            } else {
                tabs
            }
            #else
            if model.cameraDenied {
                CameraDeniedView()
            } else if !booted {
                BootingView()
            } else {
                tabs
            }
            #endif
        }
        .task {
            // Frames whose station never closed belong to a station that never
            // existed. Swept before anything reads the directory.
            let orphans = SessionStore.sweepOrphanedFrames()
            if orphans > 0 {
                logWarn(.store, "swept \(orphans) orphaned frame(s) from a station that never closed")
            }
            #if DEBUG
            if DemoSeed.isRequested {
                DemoSeed.apply(to: model)
                booted = true
                return
            }
            #endif
            await model.probe()
            model.refreshProtocols()
            model.restoreShotList()
            if orphans > 0 {
                model.status = "swept \(orphans) orphaned frame(s) from an unclosed station"
            }
            booted = true
        }
        .alert(
            "Privacy update",
            isPresented: Binding(
                get: { launchNoticeStore.message != nil },
                set: { _ in })
        ) {
            Button("OK") { launchNoticeStore.acknowledge() }
        } message: {
            Text(launchNoticeStore.message ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                CaptureFlowView(model: model, showConsole: { tab = 2 })
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { helpSettingsButton }
                    }
            }
                .tabItem { Label("Capture", systemImage: "camera.aperture") }.tag(0)
            NavigationStack {
                SessionBrowser()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { helpSettingsButton }
                    }
            }
                .tabItem { Label("Sessions", systemImage: "folder") }.tag(1)
            NavigationStack { LogConsoleView() }
                .tabItem { Label("Console", systemImage: "text.alignleft") }.tag(2)
            NavigationStack { BenchView(model: model) }
                .tabItem { Label("Bench", systemImage: "wrench.and.screwdriver") }.tag(3)
        }
        .sheet(isPresented: $showingHelpSettings) {
            NavigationStack {
                HelpSettingsView(report: model.report, model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingHelpSettings = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var helpSettingsButton: some View {
        Button { showingHelpSettings = true } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Help & Settings")
        .accessibilityHint("Opens privacy, device, diagnostics, support, and app information")
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
            Label("Camera access is off", systemImage: "exclamationmark.triangle.fill")
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

/// The bench: what this phone can be asked to do, and the two runs that measure
/// the instrument rather than use it.
///
/// It opens with capabilities rather than with buttons, because the question at
/// this screen is "what can I do with this device" — and the probe already
/// knows. The raw per-sensor numbers are still here, one level down, for when
/// the answer needs checking.
struct BenchView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var stationController: StationController

    init(model: CaptureModel) {
        self.model = model
        self.stationController = model.station
    }

    var body: some View {
        List {
            if let report = model.report {
                CapabilitySummarySection(report: report)
                runsSection
                Section("Per sensor") {
                    ForEach(report.sensors) { SensorSummaryRow(sensor: $0) }
                }
                deviceSection(report.device)
            }
        }
        .navigationTitle("Bench")
    }

}

/// Shared by the current Bench and the release Help & Settings hierarchy.
/// This is the existing capability presentation, extracted without changing
/// what it says or how it derives its values.
struct CapabilitySummarySection: View {
    let report: CapabilityReport

    var body: some View {
        Section {
            ForEach(report.capabilities) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.isConstraint
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(c.isConstraint ? Color.orange : Color.green)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.headline).font(.callout)
                        Text(c.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("What this device can do")
        } footer: {
            Text("Measured by opening each rear sensor at launch, not assumed from the model. "
                 + "The same values are recorded into every session header, so a file can be "
                 + "read later against the controls it was actually shot with.")
        }
    }
}

extension BenchView {

    /// Both runs produce a *finding about the instrument*, which is why they are
    /// not on the capture screen. Each says what question it answers, because
    /// "white-balance pixel path" means nothing to someone who has not read the
    /// ticket it came from.
    private var runsSection: some View {
        Section {
            NavigationLink {
                DeviceProfileView(model: model)
            } label: {
                runRow(icon: "ruler", tint: .orange,
                       title: "Measure this device",
                       question: "How long does this phone actually take?",
                       state: DeviceProfile.active.isCharacterised
                           ? "measured · \(DeviceProfile.active.borrowedCount) reading(s) still borrowed"
                           : "never measured — estimates borrowed from \(DeviceProfile.referenceDevice)")
            }
            NavigationLink {
                CalibrationView(model: model, bench: model.bench)
            } label: {
                runRow(icon: "moon.stars", tint: .indigo,
                       title: "Dark-frame calibration",
                       question: "What does this sensor read with no light at all?",
                       state: calibrationState)
            }
            // Developer tools, not features. They answered #14's questions,
            // which are closed, and guideline 2.3.1(a) forbids shipping a
            // hidden or undocumented feature — so they are compiled out of
            // release rather than tucked behind a toggle.
            #if DEBUG
            NavigationLink {
                InstrumentChecksView(model: model, bench: model.bench)
            } label: {
                runRow(icon: "checklist", tint: .teal,
                       title: "Instrument checks (debug)",
                       question: "Do the locks this app relies on reach the pixels?",
                       state: model.bench.zoomProbe == nil ? "not run this launch" : "run this launch")
            }
            #endif
            if let station = stationController.lastStation {
                NavigationLink {
                    LastStationView(station: station)
                } label: {
                    runRow(icon: "doc.text.magnifyingglass", tint: .gray,
                           title: "Last station · \(station.stationIndex)",
                           question: "What the four witnesses said about each frame.",
                           state: "\(station.brackets.reduce(0) { $0 + $1.frames.count }) frames")
                }
            }
        } header: {
            Text("Measuring the instrument")
        } footer: {
            Text("These are not how the app is used — a scene is shot from Capture. "
                 + "They exist so a claim made about the data has something behind it.")
        }
    }

    /// Whether there *is* a dark reference matters more than the button: a
    /// session shot without one records black level as the file's unverified
    /// assertion.
    private var calibrationState: String {
        guard let calib = SessionStore.latestCalibration() else {
            return "none on this device — black level is unmeasured"
        }
        let hours = Int(calib.ageSeconds / 3600)
        return hours < 1 ? "measured under an hour ago · \(calib.id)"
                         : "measured \(hours) h ago · \(calib.id)"
    }

    private func runRow(icon: String, tint: Color, title: String,
                        question: String, state: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(question).font(.caption2).foregroundStyle(.secondary)
                Text(state).font(.caption2).monospaced().foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func deviceSection(_ device: DeviceIdentity) -> some View {
        Section("Device") {
            LabeledContent("Model", value: device.modelIdentifier)
            LabeledContent("OS", value: "\(device.systemName) \(device.systemVersion)")
            LabeledContent("App", value: "\(device.appVersion) (\(device.appBuild))")
            if let commit = device.appCommit, commit != "unknown" {
                LabeledContent("Commit") {
                    Text(commit).monospaced().font(.caption)
                        .foregroundStyle(device.isDirtyBuild ? .orange : .secondary)
                }
                if device.isDirtyBuild {
                    Text("Uncommitted changes — this build matches no commit.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
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
struct SensorSummaryRow: View {
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
