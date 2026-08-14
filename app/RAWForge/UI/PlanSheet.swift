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
    @Environment(\.dismiss) private var dismiss
    @State private var creatingProtocol = false

    private var isEditable: Bool { model.phase == .sessionOpen || model.phase == .noSession }

    private var estimate: SessionEstimate {
        SessionEstimate.forShotList(model.shotList.entries, mode: model.mode,
                                    minimumGap: model.minimumGap)
    }

    var body: some View {
        NavigationStack {
            List {
                if !isEditable { lockedNotice }
                shotListSection
                if !model.shotList.entries.isEmpty { summarySection }
                settingsSection
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isEditable && !model.shotList.entries.isEmpty { EditButton() }
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
            if model.shotList.entries.isEmpty {
                Text("Nothing planned. A station with nothing to shoot is not a station.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.shotList.entries.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(pipColour(i)).frame(width: 22, height: 22)
                        Text("\(i + 1)").font(.caption2).bold().foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.captureSet.name).font(.callout)
                        Text("\(e.sensor.rawValue) · v\(e.captureSet.version) · \(e.frameCount) frames")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if i < model.shotList.cursor {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .onDelete { if isEditable { model.removeFromShotList(at: $0) } }
            .onMove { s, d in if isEditable { model.moveInShotList(from: s, to: d) } }

            if isEditable { addControl }
        } header: {
            HStack {
                Text("Shot list")
                Spacer()
                if !model.shotList.entries.isEmpty {
                    Text("\(model.shotList.totalFrames) frames").font(.caption2)
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
                            model.addToShotList(p, sensor: only.sensor)
                        }
                    } else {
                        Menu("\(p.name) · \(p.specs.count) frames") {
                            ForEach(sensors) { cap in
                                Button(cap.sensor.rawValue) {
                                    model.addToShotList(p, sensor: cap.sensor)
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

    private func pipColour(_ i: Int) -> Color {
        i < model.shotList.cursor ? .green : i == model.shotList.cursor ? .accentColor : .secondary
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
                PoseIntentView(model: model)
            } label: {
                LabeledContent("Pose") {
                    Text(model.poseIntent.isEmpty ? "unset" : model.poseIntent)
                        .foregroundStyle(model.poseIntent.isEmpty ? .orange : .secondary)
                }
            }
            NavigationLink {
                ExecutionView(model: model)
            } label: {
                LabeledContent("How it fires") {
                    Text(model.mode == .hardwareBracket ? "bracket" : "sequential")
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProtocolLibraryView(model: model)
            } label: {
                LabeledContent("Protocols") {
                    Text("\(model.savedProtocols.count) saved").foregroundStyle(.secondary)
                }
            }
            if isEditable && !model.shotList.entries.isEmpty {
                Toggle("Group by sensor", isOn: $model.groupShotListBySensor)
                    .onChange(of: model.groupShotListBySensor) { model.regroupShotList() }
                Button("Clear shot list", role: .destructive) { model.clearShotList() }
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
    @ObservedObject var model: CaptureModel

    var body: some View {
        List {
            Section {
                ForEach(CaptureModel.poseIntentPresets, id: \.self) { preset in
                    Button {
                        model.poseIntent = preset
                    } label: {
                        HStack {
                            Text(preset)
                            Spacer()
                            if model.poseIntent == preset {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Or describe it") {
                TextField("how the phone is held", text: $model.poseIntent)
            }
            if model.poseIntent.isEmpty {
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

/// How sets are fired, as opposed to what they contain. Both modes are first
/// class — the choice is about inter-frame gap, not about what can be expressed.
private struct ExecutionView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $model.mode) {
                    ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.mode == .hardwareBracket
                     ? "One hardware request carries every rung's exposure, so the device is "
                       + "never reconfigured mid-run and the gap is pipeline-bound. Capped by "
                       + "the sensor's bracket maximum."
                     : "One exposure lock per rung, each awaited. Unbounded in length — with "
                       + "identical rungs nothing changes and nothing has to settle.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Timing") {
                Stepper(value: $model.minimumGap, in: 0...5, step: 0.25) {
                    LabeledContent("Min inter-frame gap",
                                   value: model.minimumGap == 0 ? "none"
                                          : String(format: "%.2f s", model.minimumGap))
                }
                Stepper(value: $model.dwell, in: 0...5, step: 0.25) {
                    LabeledContent("Extra dwell before first frame",
                                   value: model.dwell == 0 ? "none"
                                          : String(format: "%.2f s", model.dwell))
                }
                Text("The flow already waits 0.4 s for the tap transient to decay — the measured "
                     + "time a finger-lift takes. Add dwell only for a mount that rings longer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("How it fires")
        .navigationBarTitleDisplayMode(.inline)
    }
}
