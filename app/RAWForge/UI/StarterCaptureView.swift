import SwiftUI

/// The first-use empty state: three real recipes, not a tutorial and not a
/// second capture mode.
///
/// Choosing one leads to the same shot list and capture controller as a set
/// authored in the full editor. The only thing skipped is naming and building
/// the common shape by hand.
struct StarterCaptureChoices: View {
    @ObservedObject var model: CaptureModel
    let startCustom: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose what you want to capture.")
                    .font(.headline)
                Text("Review the recipe, pick a sensor, then add it to your plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            ForEach(StarterCapture.allCases) { starter in
                NavigationLink {
                    StarterCaptureReview(model: model, starter: starter)
                } label: {
                    StarterCaptureRow(starter: starter)
                }
                .accessibilityHint("Review this recipe before adding it to the shot list")
            }

            Button(action: startCustom) {
                Label("Build a custom recipe", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Start a plan")
        } footer: {
            Text("Every starter becomes a named, versioned protocol. Nothing is captured "
                 + "with hidden settings, and you can edit or reuse it later.")
        }
    }
}

private struct StarterCaptureRow: View {
    let starter: StarterCapture

    private var set: CaptureSet {
        starter.captureSet(firing: starter.defaultFiringMode)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: starter.presentation.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(starter.presentation.title).font(.callout).bold()
                    Spacer(minLength: 6)
                    Text("\(set.specs.count)f")
                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                }
                Text(starter.presentation.summary)
                    .font(.caption2).foregroundStyle(.secondary)
                if set.specs.count > 1 {
                    LadderBars(rungs: starter.relativeRungs)
                        .frame(maxWidth: 150)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Compact review before a starter becomes durable state.
///
/// Burst/Sequential is exposed here because it changes the meaning of a
/// protocol record. Single omits the picker because one frame has no
/// inter-frame behavior to choose.
struct StarterCaptureReview: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var station: StationController
    let starter: StarterCapture

    @Environment(\.dismiss) private var dismiss
    @State private var firing: ExecutionMode
    @State private var selectedSensor: SensorCapability.Sensor
    @State private var notice: String?

    init(model: CaptureModel, starter: StarterCapture) {
        self.model = model
        self.station = model.station
        self.starter = starter
        _firing = State(initialValue: starter.defaultFiringMode)
        _selectedSensor = State(initialValue: model.report?.usableSensors.first?.sensor ?? .wide)
    }

    private var set: CaptureSet { starter.captureSet(firing: firing) }
    private var sensors: [SensorCapability] { model.report?.usableSensors ?? [] }
    private var capability: SensorCapability? {
        sensors.first { $0.sensor == selectedSensor }
    }
    private var checked: CaptureSet.Validated? { capability.map { set.validated(against: $0) } }

    private var estimate: SessionEstimate {
        let entry = ShotListEntry(index: 0, sensor: selectedSensor, captureSet: set)
        return SessionEstimate.forShotList([entry], minimumGap: station.minimumGap,
                                           bracketCeiling: capability?.maxBracketedCapturePhotoCount)
    }

    var body: some View {
        List {
            recipeSection
            sensorSection
            firingSection
            costSection
            addSection
        }
        .navigationTitle(starter.presentation.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recipeSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: starter.presentation.symbol)
                    .font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.presentation.recipeHeadline).font(.callout)
                    Text(starter.presentation.exposureSummary)
                        .font(.caption).monospaced().foregroundStyle(.secondary)
                }
            }
            if set.specs.count > 1 {
                LadderBars(rungs: starter.relativeRungs,
                           seamAfter: seamCount > 0 ? capability?.maxBracketedCapturePhotoCount : nil)
                    .padding(.vertical, 4)
            }
        } header: {
            Text("Recipe")
        } footer: {
            Text("Uses fixed values—nothing is taken from preview metering.")
        }
    }

    @ViewBuilder private var sensorSection: some View {
        Section("Sensor") {
            if sensors.count > 1 {
                Picker("Camera", selection: $selectedSensor) {
                    ForEach(sensors) { Text($0.sensor.rawValue).tag($0.sensor) }
                }
                .pickerStyle(.segmented)
            } else if let sensor = sensors.first {
                LabeledContent("Camera", value: sensor.sensor.rawValue)
            }

            if let checked, !checked.dropped.isEmpty {
                Label("This sensor cannot make \(checked.dropped.count) rung(s). They would be "
                      + "recorded as dropped, never silently clamped.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var firingSection: some View {
        Section {
            if starter.allowedFiringModes.count > 1 {
                Picker("Firing", selection: $firing) {
                    ForEach(starter.allowedFiringModes) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(firing.explanation).font(.caption2).foregroundStyle(.secondary)
                if seamCount > 0 {
                    Label("This phone holds \(capability?.maxBracketedCapturePhotoCount ?? 0) frames "
                          + "per Burst, so RAWForge will bank \(seamCount + 1) requests.",
                          systemImage: "rectangle.split.2x1")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                LabeledContent("Firing", value: "Single request")
                Text("One frame has no inter-frame behavior to choose.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("How it fires")
        }
    }

    private var costSection: some View {
        Section("What it costs") {
            HStack(spacing: 18) {
                figure("\(set.specs.count)", "frames")
                figure(SessionEstimate.formatDuration(estimate.typicalSeconds), "typical")
                figure(SessionEstimate.formatBytes(estimate.typicalBytes), "on disk")
            }
            TimeBudgetBar(breakdown: estimate.breakdown)
            if let fits = estimate.fitsAvailableStorage, !fits {
                Label("This set will not fit at worst case.",
                      systemImage: "exclamationmark.octagon.fill")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private var addSection: some View {
        Section {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Button(action: addToPlan) {
                Label("Add \(set.specs.count)-frame set to plan", systemImage: "plus.circle.fill")
                    .bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(capability == nil || checked?.kept.isEmpty == true)

            Text("Saved as “\(set.name)” before it enters the shot list. If that name belongs "
                 + "to a customized recipe, RAWForge creates a numbered sibling instead.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var seamCount: Int {
        guard firing == .hardwareBracket, let ceiling = capability?.maxBracketedCapturePhotoCount,
              ceiling > 0 else { return 0 }
        return max(0, SessionEstimate.requestCount(frames: set.specs.count, ceiling: ceiling) - 1)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout).monospaced()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func addToPlan() {
        do {
            let stored = try ProtocolLibrary.materializeStarter(set)
            model.refreshProtocols()
            station.addToShotList(stored, sensor: selectedSensor)
            logInfo(.flow, "starter \(starter.rawValue) materialized as \(stored.name) "
                    + "v\(stored.version) on \(selectedSensor.rawValue)")
            dismiss()
        } catch {
            notice = "Could not save the protocol — \(error.localizedDescription)"
            logFailure(.store, "materializing starter \(starter.rawValue)", error)
        }
    }
}

private struct StarterPresentation {
    let title: String
    let summary: String
    let symbol: String
    let recipeHeadline: String
    let exposureSummary: String
}

private extension StarterCapture {
    var presentation: StarterPresentation {
        let specs = captureSet(firing: defaultFiringMode).specs
        switch self {
        case .exposureLadder:
            return StarterPresentation(
                title: "Exposure Ladder",
                summary: "7 exposures · ±3 stops · Burst by default",
                symbol: "camera.metering.matrix",
                recipeHeadline: "7 frames · 1 stop apart",
                exposureSummary: "\(specs.first?.shutterLabel ?? "–") → "
                    + "\(specs.last?.shutterLabel ?? "–") · ISO 100")
        case .repeat16:
            return StarterPresentation(
                title: "Repeat",
                summary: "16 identical exposures · Burst by default",
                symbol: "square.stack.3d.up",
                recipeHeadline: "16 identical frames",
                exposureSummary: "1/125 · ISO 100")
        case .single:
            return StarterPresentation(
                title: "Single Frame",
                summary: "1 authored exposure",
                symbol: "camera",
                recipeHeadline: "1 frame",
                exposureSummary: "1/125 · ISO 100")
        }
    }

    var relativeRungs: [Double] {
        let specs = captureSet(firing: defaultFiringMode).specs
        let longest = specs.map(\.shutterSeconds).max() ?? 1
        return specs.map { longest > 0 ? $0.shutterSeconds / longest : 1 }
    }

}
