import SwiftUI

/// The everyday surface has one capture intent. Internal session/station
/// transitions remain in StationController, never in these buttons.
struct ShootView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var workflow: RecipeCoordinator
    @ObservedObject var station: StationController
    @State private var editing: Recipe?
    @State private var error: String?
    @State private var showFocus = false

    init(model: CaptureModel) {
        self.model = model
        workflow = model.workflow
        station = model.station
        #if DEBUG
        if DemoSeed.value == "recipe-editor" { _editing = State(initialValue: model.workflow.selectedRecipe) }
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let recipe = workflow.selectedRecipe {
                    Button { editing = recipe } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recipe.name).font(.title2).bold()
                                Text("\(recipe.steps.count) \(recipe.steps.count == 1 ? "step" : "steps") · \(frameCount(recipe)) \(frameCount(recipe) == 1 ? "frame" : "frames") · v\(recipe.version)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text(recipe.steps.map { "\($0.sensor.rawValue) · \($0.captureSet.firing.label)" }.joined(separator: " → "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "slider.horizontal.3")
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(station.busy)
                    ViewfinderPanel(model: model)
                        .frame(height: max(220, geometry.size.height * 0.48))
                        .frame(maxWidth: .infinity)
                    HStack {
                        Button { showFocus = true } label: { Label("Focus", systemImage: "viewfinder") }
                            .disabled(station.busy)
                        Spacer()
                        if let estimate = estimate {
                            Text("≈ \(SessionEstimate.formatDuration(estimate.worstCaseSeconds)) · \(SessionEstimate.formatBytes(estimate.typicalBytes))")
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }.frame(minHeight: 44)
                    validationDetails
                    if let notice = workflow.notice {
                        Text(notice).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
                    }
                    if station.busy {
                        ProgressView(station.progress.isEmpty ? station.phase.title : station.progress)
                    } else {
                        Text(station.session == nil ? "A new Run starts automatically."
                             : "Ready for another Take. Earlier captures are saved.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("No RAW camera available", systemImage: "camera",
                        description: Text("Check This iPhone in Help & Settings for the available camera capabilities."))
                }
            }.padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            if workflow.selectedRecipe != nil {
                Group {
                    if station.busy {
                        Button(station.shotList.current?.captureSet.firing == .sequential
                               ? "Stop after current frame" : "Stop after current burst", role: .destructive) {
                            station.requestStop()
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Button { Task { await workflow.capture() } } label: {
                            Label("Capture", systemImage: "camera.aperture")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workflow.validation?.canCapture != true || workflow.validation?.hasWarnings == true)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .systemBackground))
            }
        }
        }
        .navigationTitle("Shoot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if station.session != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Finish Run") { perform { try workflow.finishRun() } }
                    } label: { Label("Run", systemImage: "folder") }
                    .disabled(station.busy)
                }
            }
        }
        .sheet(item: $editing) { recipe in
            NavigationStack { RecipeEditorView(recipe: recipe, report: model.report, save: workflow.save) }
        }
        .sheet(isPresented: $showFocus, onDismiss: { station.startFraming() }) {
            NavigationStack {
                FocusPreflightView(model: model).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showFocus = false } }
                }
            }
        }
        .alert("Could not update Run", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { station.startFraming() }
    }

    private var estimate: SessionEstimate? {
        workflow.selectedRecipe.map {
            SessionEstimate.forShotList($0.renderedEntries(), minimumGap: 0, bracketCeiling: station.bracketCeiling)
        }
    }

    private func frameCount(_ recipe: Recipe) -> Int { recipe.steps.reduce(0) { $0 + $1.captureSet.specs.count } }

    @ViewBuilder private var validationDetails: some View {
        if let validation = workflow.validation {
            ForEach(Array(validation.blockers.enumerated()), id: \.offset) { _, blocker in
                Label(blocker.message, systemImage: "exclamationmark.triangle").font(.subheadline)
            }
            if validation.hasWarnings {
                DisclosureGroup("Review unsupported frames") {
                    ForEach(validation.steps, id: \.stepID) { step in
                        ForEach(Array(step.dropped.enumerated()), id: \.offset) { _, rung in
                            Text("Step \(step.stepIndex + 1): \(rung.reason)").font(.footnote)
                        }
                    }
                    Button("Save adapted copy without these frames") { perform { try workflow.adaptedCopy() } }
                        .disabled(!validation.canCapture || station.busy)
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

struct CaptureLibraryView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var workflow: RecipeCoordinator
    @ObservedObject var station: StationController
    @State private var editing: Recipe?
    @State private var error: String?

    init(model: CaptureModel) {
        self.model = model
        workflow = model.workflow
        station = model.station
    }

    var body: some View {
        List {
            Section {
                NavigationLink { SessionBrowser(protectedSessionID: station.session?.sessionId) } label: {
                    Label("Captured Runs", systemImage: "photo.stack")
                }.disabled(station.busy)
            }
            Section {
                ForEach(workflow.library) { recipe in
                    Button { perform { try workflow.select(recipe) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recipe.name).foregroundStyle(.primary)
                                Text("\(recipe.steps.count) steps · v\(recipe.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if workflow.selectedRecipe?.id == recipe.id && workflow.selectedRecipe?.version == recipe.version {
                                Image(systemName: "checkmark")
                            }
                        }.frame(minHeight: 44)
                    }
                    .disabled(station.busy)
                    .contextMenu {
                        Button("Edit", systemImage: "slider.horizontal.3") { editing = recipe }
                        Button("Duplicate", systemImage: "doc.on.doc") { perform { try workflow.duplicate(recipe) } }
                    }
                }
            } header: { Text("Recipes") }
              footer: { Text("Select a Recipe, then return to Shoot. Hold a Recipe to edit or duplicate it.") }
            if let selected = workflow.selectedRecipe {
                Button("Edit selected Recipe") { editing = selected }.disabled(station.busy)
            }
            Section {
                DisclosureGroup("Advanced library tools") {
                    NavigationLink("Existing protocol library") { ProtocolLibraryView(model: model) }
                        .disabled(station.busy)
                    Text("Older exposure definitions remain editable here and can be added as Recipe Steps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { newRecipe() } label: { Label("New Recipe", systemImage: "plus") }
                    .disabled(station.busy || model.report?.canCapture != true)
            }
        }
        .sheet(item: $editing) { recipe in
            NavigationStack { RecipeEditorView(recipe: recipe, report: model.report, save: workflow.save) }
        }
        .alert("Recipe not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func newRecipe() {
        guard let first = model.report?.usableSensors.first else { return }
        let now = Date()
        let step = RecipeStep(id: UUID(), sensor: first.sensor,
            captureSet: StarterCapture.single.captureSet(firing: .hardwareBracket), dwellSeconds: 0)
        editing = Recipe(id: UUID(), name: "New Recipe", version: 1, createdAt: now,
                         modifiedAt: now, steps: [step], note: nil, schemaVersion: 1)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

struct RecipeEditorView: View {
    @State var recipe: Recipe
    let report: CapabilityReport?
    let save: (Recipe) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Recipe name", text: $recipe.name)
            }
            Section {
                ForEach($recipe.steps) { $step in
                    NavigationLink {
                        RecipeStepEditor(step: $step, sensors: report?.sensors ?? [])
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\((recipe.steps.firstIndex { $0.id == step.id } ?? 0) + 1). \(step.captureSet.name)").font(.headline)
                            Text("\(step.sensor.rawValue) · \(step.captureSet.specs.count) \(step.captureSet.specs.count == 1 ? "frame" : "frames") · \(step.captureSet.firing.label)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
                .onMove { recipe.steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { recipe.steps.remove(atOffsets: $0) }
                Menu {
                    ForEach(StarterCapture.allCases) { starter in
                        Button(starter.captureSet(firing: .hardwareBracket).name) { add(starter.captureSet(firing: .hardwareBracket)) }
                    }
                    Menu("Add from existing protocols") {
                        ForEach(Array(ProtocolLibrary.all().enumerated()), id: \.offset) { _, set in
                            Button(set.name) { add(set) }
                        }
                    }
                } label: { Label("Add Step", systemImage: "plus") }
            } header: { Text("Steps · captured from top to bottom") }
              footer: { Text("Tap a Step for camera, exposure and timing. Use Edit to move or remove Steps.") }
            Section {
                TextField("Optional note", text: Binding(get: { recipe.note ?? "" }, set: { recipe.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
            if let report {
                let validation = RecipeValidator.validate(recipe, against: report)
                if !validation.canCapture || validation.hasWarnings {
                    Section("Camera compatibility") {
                        ForEach(Array(validation.blockers.enumerated()), id: \.offset) { _, blocker in Text(blocker.message) }
                        ForEach(validation.steps, id: \.stepID) { step in
                            ForEach(Array(step.dropped.enumerated()), id: \.offset) { _, rung in Text("Step \(step.stepIndex + 1): \(rung.reason)") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Edit Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .bottomBar) { EditButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do { try save(recipe); dismiss() } catch { self.error = error.localizedDescription }
                }.disabled(recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recipe.steps.isEmpty)
            }
        }
        .interactiveDismissDisabled()
        .alert("Recipe not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func add(_ set: CaptureSet) {
        guard let sensor = report?.usableSensors.first?.sensor else { return }
        recipe.steps.append(RecipeStep(id: UUID(), sensor: sensor, captureSet: set, dwellSeconds: 0))
    }
}
