import SwiftUI

/// Planning, kept off the capture screen.
///
/// A station is authored before the walk and shot at the pose, and mixing the
/// two puts a picker next to a shutter. So everything that decides *what* will
/// be captured lives here, and the capture screen keeps only what happens now.
///
/// The screen is arranged around the one thing done often — adding a set —
/// which is a single menu rather than two pickers and a button. Managing the
/// protocol library and changing how sets fire are done rarely, so they are one
/// level down instead of competing for the same space.
///
/// The shot list is editable only before a station is declared. Once it is, the
/// list is that station's definition, and changing it mid-flight would mean the
/// record described something other than what was shot.
struct PlanSheet: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var station: StationController
    @Environment(\.dismiss) private var dismiss
    @State private var creatingProtocol = false

    init(model: CaptureModel) {
        self.model = model
        self.station = model.station
    }

    private var isEditable: Bool { station.phase == .sessionOpen || station.phase == .noSession }

    private var estimate: SessionEstimate {
        SessionEstimate.forShotList(station.shotList.entries,
                                    minimumGap: station.minimumGap,
                                    bracketCeiling: station.bracketCeiling)
    }

    var body: some View {
        NavigationStack {
            List {
                if !isEditable { lockedNotice }
                if isEditable && station.shotList.entries.isEmpty
                    && model.savedProtocols.isEmpty {
                    StarterCaptureChoices(model: model) { creatingProtocol = true }
                } else {
                    shotListSection
                }
                if !station.shotList.entries.isEmpty { summarySection }
                settingsSection
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isEditable && !station.shotList.entries.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .sheet(isPresented: $creatingProtocol) {
                ProtocolEditorView(model: model, editing: nil)
            }
        }
    }

    private var lockedNotice: some View {
        Section {
            Label("The shot list is fixed once a station is declared.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - The list, and the one action

    private var shotListSection: some View {
        Section {
            if station.shotList.entries.isEmpty {
                Text("Nothing planned. A station with nothing to shoot is not a station.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(station.shotList.entries.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(pipColour(i)).frame(width: 22, height: 22)
                        Text("\(i + 1)").font(.caption2).bold().foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.captureSet.name).font(.callout)
                        Text("\(e.sensor.rawValue) · v\(e.captureSet.version) · "
                             + "\(e.frameCount) frames · \(e.captureSet.firing.label.lowercased())")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if i < station.shotList.cursor {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .onDelete { if isEditable { station.removeFromShotList(at: $0) } }
            .onMove { s, d in if isEditable { station.moveInShotList(from: s, to: d) } }

            if isEditable { addControl }
        } header: {
            HStack {
                Text("Shot list")
                Spacer()
                if !station.shotList.entries.isEmpty {
                    Text("\(station.shotList.totalFrames) frames").font(.caption2)
                }
            }
        }
    }

    /// One tap to open, one to pick the protocol, one to pick the sensor — and
    /// on a single-sensor device the last step disappears rather than being a
    /// menu of one.
    @ViewBuilder private var addControl: some View {
        let sensors = model.report?.usableSensors ?? []
        if model.savedProtocols.isEmpty {
            Button {
                creatingProtocol = true
            } label: {
                Label("Create your first protocol", systemImage: "plus.circle.fill")
            }
        } else {
            Menu {
                ForEach(model.savedProtocols, id: \.name) { p in
                    if sensors.count <= 1, let only = sensors.first {
                        Button("\(p.name) · \(p.specs.count) frames") {
                            station.addToShotList(p, sensor: only.sensor)
                        }
                    } else {
                        Menu("\(p.name) · \(p.specs.count) frames") {
                            ForEach(sensors) { cap in
                                Button(cap.sensor.rawValue) {
                                    station.addToShotList(p, sensor: cap.sensor)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    creatingProtocol = true
                } label: {
                    Label("New protocol…", systemImage: "square.and.pencil")
                }
            } label: {
                Label("Add set", systemImage: "plus.circle.fill")
            }
        }
    }

    /// Nothing unusual set reads as "nothing unusual set", so the row does not
    /// invite a visit it does not need.
    private var advancedSummary: String {
        var bits: [String] = []
        if station.dwell > 0 { bits.append(String(format: "%.2f s dwell", station.dwell)) }
        if station.minimumGap > 0 && hasSequentialSet {
            bits.append(String(format: "%.2f s gap", station.minimumGap))
        }
        return bits.isEmpty ? "defaults" : bits.joined(separator: " · ")
    }

    private var hasSequentialSet: Bool {
        station.shotList.entries.contains { $0.captureSet.firing == .sequential }
    }

    /// The sensors this station will actually use, in the order they appear.
    private var plannedSensors: [SensorCapability.Sensor] {
        var seen: [SensorCapability.Sensor] = []
        for e in station.shotList.entries where !seen.contains(e.sensor) { seen.append(e.sensor) }
        return seen
    }

    private func pipColour(_ i: Int) -> Color {
        i < station.shotList.cursor ? .green : i == station.shotList.cursor ? .accentColor : .secondary
    }

    // MARK: - What it will cost

    /// Three numbers and a verdict. The step-by-step breakdown is one tap away
    /// rather than occupying the screen — it is read once when a plan is being
    /// designed, not every time a set is added.
    private var summarySection: some View {
        let e = estimate
        return Section {
            NavigationLink {
                StationTimelineView(model: model)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        figure("\(e.frameCount)", "frames")
                        figure(SessionEstimate.formatDuration(e.typicalSeconds), "typical")
                        figure(SessionEstimate.formatBytes(e.typicalBytes), "on disk")
                    }
                    TimeBudgetBar(breakdown: e.breakdown)
                    Text(String(format: "%.0f%% of it is not shooting",
                                100 * e.breakdown.notShooting))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let fits = e.fitsAvailableStorage, !fits {
                        Label("Will not fit at worst case — the station would abort mid-shoot.",
                              systemImage: "exclamationmark.octagon.fill")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    if model.health.thermalWarning || model.health.batteryWarning {
                        Text(model.health.summary).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Cost")
        } footer: {
            Text("The pose must be held for all of it — sensor swaps and settling included.")
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.callout).monospaced()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Set once, rarely changed

    private var settingsSection: some View {
        Section {
            NavigationLink {
                PoseIntentView(station: station)
            } label: {
                LabeledContent("Pose") {
                    Text(station.poseIntent.isEmpty ? "unset" : station.poseIntent)
                        .foregroundStyle(station.poseIntent.isEmpty ? .orange : .secondary)
                }
            }
            // Focus sits beside Pose because it is the same kind of thing: a
            // property of *this* pose that cannot be authored in advance. A
            // lens position means nothing away from what it was focused on, so
            // it is never part of a protocol (#18).
            NavigationLink {
                FocusPreflightView(model: model)
            } label: {
                LabeledContent("Focus") {
                    Text(station.focusPlan.summary(for: plannedSensors))
                        .foregroundStyle(.secondary)
                }
            }
            // How a set fires belongs to the set, not to the shoot — so this is
            // no longer a switch here. It is chosen when the protocol is
            // written, and shown on every row of the shot list.
            NavigationLink {
                AdvancedView(station: station)
            } label: {
                LabeledContent("Advanced") {
                    Text(advancedSummary).foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProtocolLibraryView(model: model)
            } label: {
                LabeledContent("Protocols") {
                    Text("\(model.savedProtocols.count) saved").foregroundStyle(.secondary)
                }
            }
            if isEditable && !station.shotList.entries.isEmpty {
                Toggle("Group by sensor", isOn: $station.groupShotListBySensor)
                    .onChange(of: station.groupShotListBySensor) { station.regroupShotList() }
                Button("Clear shot list", role: .destructive) { station.clearShotList() }
            }
        }
    }
}

/// The plan step by step, including the steps that cost the most and are
/// easiest to forget — a sensor swap runs longer than an entire 8-frame
/// bracket, and a plan that hides its most expensive step is misleading.
private struct StationTimelineView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        List { StationPlanView(model: model) }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The pose label is the only thing distinguishing conditions that differ solely
/// in how the phone was held. Two stations have already been mislabelled — one
/// typo, one left blank — so the presets make the ordinary case one tap without
/// constraining what a station can be.
private struct PoseIntentView: View {
    @ObservedObject var station: StationController

    var body: some View {
        List {
            Section {
                ForEach(CaptureModel.poseIntentPresets, id: \.self) { preset in
                    Button {
                        station.poseIntent = preset
                    } label: {
                        HStack {
                            Text(preset)
                            Spacer()
                            if station.poseIntent == preset {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Or describe it") {
                TextField("how the phone is held", text: $station.poseIntent)
            }
            if station.poseIntent.isEmpty {
                Section {
                    Label("An unlabelled station cannot be told apart later from one held "
                          + "differently.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Pose intent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The two expert knobs, kept off the path to a first capture.
///
/// Neither was set once across the first 25 real stations, which is the reason
/// they are here rather than in the plan proper — but neither is cut, because
/// each is the only lever for a case the app cannot rule out.
private struct AdvancedView: View {
    @ObservedObject var station: StationController

    private var hasSequentialSet: Bool {
        station.shotList.entries.contains { $0.captureSet.firing == .sequential }
    }

    var body: some View {
        List {
            Section("Timing") {
                // Only shown when the shot list holds a sequential set: a burst
                // is one hardware request with nowhere to insert a wait, so the
                // control would silently do nothing.
                if hasSequentialSet {
                    Stepper(value: $station.minimumGap, in: 0...5, step: 0.25) {
                        LabeledContent("Min gap between frames",
                                       value: station.minimumGap == 0 ? "none"
                                              : String(format: "%.2f s", station.minimumGap))
                    }
                    Text("Sequential only. Spaces frames deliberately — to pace a long run "
                         + "rather than let it heat the sensor.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Stepper(value: $station.dwell, in: 0...5, step: 0.25) {
                    LabeledContent("Extra dwell before first frame",
                                   value: station.dwell == 0 ? "none"
                                          : String(format: "%.2f s", station.dwell))
                }
                Text("The flow already waits 0.4 s for the tap transient to decay — the measured "
                     + "time a finger-lift takes. Add dwell only for a mount that rings longer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}
