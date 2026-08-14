import SwiftUI

/// Planning, kept off the capture screen.
///
/// A station is authored before the walk and shot at the pose, and mixing the
/// two puts a picker next to a shutter. So everything that decides *what* will
/// be captured lives here, and the capture screen keeps only what happens *now*.
///
/// The shot list is editable only before a station is declared. Once it is, the
/// list is the station's definition and changing it mid-flight would mean the
/// record described something other than what was shot.
struct PlanSheet: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingProtocolEditor = false

    var body: some View {
        NavigationStack {
            List {
                if model.phase != .sessionOpen && model.phase != .noSession {
                    Section {
                        Label("The shot list is fixed once a station is declared.",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                shotListSection
                if model.phase == .sessionOpen || model.phase == .noSession { addSection }
                executionSection
                StationPlanView(model: model)
                poseSection
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
            .sheet(isPresented: $showingProtocolEditor) {
                ProtocolEditorView(model: model)
            }
        }
        .presentationDetents([.large])
    }

    private var isEditable: Bool { model.phase == .sessionOpen || model.phase == .noSession }

    // MARK: - The list

    private var shotListSection: some View {
        Section {
            if model.shotList.entries.isEmpty {
                ContentUnavailableView {
                    Label("No sets planned", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("A station with nothing to shoot is not a station. "
                         + "Add a protocol below.")
                }
                .frame(maxHeight: 180)
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

    private func pipColour(_ i: Int) -> Color {
        i < model.shotList.cursor ? .green : i == model.shotList.cursor ? .accentColor : .secondary
    }

    // MARK: - Adding

    private var addSection: some View {
        Section("Add a set") {
            if let report = model.report {
                Picker("Sensor", selection: $model.builderSensor) {
                    ForEach(report.usableSensors) { Text($0.sensor.rawValue).tag($0.sensor) }
                }
                Picker("Protocol", selection: $model.builderProtocolName) {
                    Text("choose…").tag("")
                    ForEach(model.savedProtocols, id: \.name) {
                        Text("\($0.name) v\($0.version)").tag($0.name)
                    }
                }
                Button {
                    model.addToShotList()
                } label: {
                    Label("Add to shot list", systemImage: "plus.circle.fill")
                }
                .disabled(model.builderProtocolName.isEmpty)

                if model.savedProtocols.isEmpty {
                    Label("No protocols saved yet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    showingProtocolEditor = true
                } label: {
                    Label("New protocol…", systemImage: "square.and.pencil")
                }

                // Grouping is the default; reordering the list is what turns it
                // off, because moving an entry is authoring an order.
                Toggle("Group by sensor", isOn: $model.groupShotListBySensor)
                    .onChange(of: model.groupShotListBySensor) { model.regroupShotList() }
                if !model.shotList.entries.isEmpty {
                    Button("Clear shot list", role: .destructive) { model.clearShotList() }
                }
            }
        }
    }

    // MARK: - Execution

    /// How the sets are fired, as opposed to what they contain. Both modes are
    /// first class — the choice is about inter-frame gap, not about what can be
    /// expressed.
    private var executionSection: some View {
        Section {
            Picker("Mode", selection: $model.mode) {
                ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.mode == .hardwareBracket
                 ? "One hardware request carries every rung's exposure, so the device is never "
                   + "reconfigured mid-run and the gap is pipeline-bound. Capped by the sensor's "
                   + "bracket maximum."
                 : "One exposure lock per rung, each awaited. Unbounded in length — with "
                   + "identical rungs nothing changes and nothing has to settle.")
                .font(.caption2).foregroundStyle(.secondary)

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
        } header: {
            Text("Execution")
        }
    }

    // MARK: - Pose

    /// The pose label is the only thing that distinguishes conditions differing
    /// solely in how the phone was held. Two stations have already been
    /// mislabelled — one typo, one left blank — so the presets are here to make
    /// the ordinary case one tap, not to constrain what a station can be.
    private var poseSection: some View {
        Section("Pose intent") {
            Picker("Preset", selection: $model.poseIntent) {
                Text("— unset —").tag("")
                ForEach(CaptureModel.poseIntentPresets, id: \.self) { Text($0).tag($0) }
                if !model.poseIntent.isEmpty
                    && !CaptureModel.poseIntentPresets.contains(model.poseIntent) {
                    Text(model.poseIntent).tag(model.poseIntent)
                }
            }
            TextField("or type one", text: $model.poseIntent).font(.callout)
            if model.poseIntent.isEmpty {
                Label("An unlabelled station cannot be told apart later from one held "
                      + "differently.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
