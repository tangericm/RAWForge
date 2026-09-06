import SwiftUI

/// Exact values stay editable. Generating a series is an explicit replacement
/// of the draft's frames, never an implicit regeneration of an imported set.
struct RecipeStepEditor: View {
    @Binding var step: RecipeStep
    let sensors: [SensorCapability]
    @State private var frameCount = 16
    @State private var shutter = 0.008
    @State private var iso: Float = 100
    @State private var stops = 1.0
    @State private var error: String?
    @State private var confirmingBurst = false

    var body: some View {
        List {
            Section {
                Picker("Camera", selection: $step.sensor) {
                    ForEach(SensorCapability.Sensor.allCases, id: \.self) { sensor in
                        Text(sensor.rawValue + (sensors.first { $0.sensor == sensor }?.isUsable == true ? "" : " · unavailable"))
                            .tag(sensor)
                    }
                }
                Picker("Firing", selection: Binding(get: { step.captureSet.firing }, set: {
                    if $0 == .hardwareBracket, (step.sequentialGapSeconds ?? 0) > 0 {
                        confirmingBurst = true
                        return
                    }
                    replace(specs: step.captureSet.specs, generator: step.captureSet.generator, firing: $0)
                    step.sequentialGapSeconds = $0 == .sequential ? step.sequentialGapSeconds ?? 0 : nil
                })) {
                    Text("Burst").tag(ExecutionMode.hardwareBracket)
                    Text("Sequential").tag(ExecutionMode.sequential)
                }.pickerStyle(.segmented)
                Text(step.captureSet.firing.explanation).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Timing") {
                HStack {
                    Text("Wait before Step (s)")
                    Spacer()
                    TextField("Seconds", value: $step.dwellSeconds, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                if step.captureSet.firing == .sequential {
                    HStack {
                        Text("Minimum frame interval (s)")
                        TextField("Seconds", value: Binding(get: { step.sequentialGapSeconds ?? 0 },
                            set: { step.sequentialGapSeconds = $0 }), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Minimum frame interval in seconds")
                            .accessibilityIdentifier("step.interval")
                    }
                    Text("Start-to-start minimum. Exposure and writing may take longer. Burst always fires as quickly as the camera allows.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Generate a repeat or exposure ladder") {
                    number("Frames", value: $frameCount)
                    number("Base shutter (s)", value: $shutter)
                    number("Base ISO", value: $iso)
                    number("Stops per rung", value: $stops)
                    Button("Replace with repeat") { generate(sweep: false) }
                    Button("Replace with exposure ladder") { generate(sweep: true) }
                    Text("Replaces the frame values below. The Recipe is not changed until you save.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Exact frame values · \(step.captureSet.specs.count)") {
                ForEach(step.captureSet.specs.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Frame \(index + 1)").font(.subheadline).bold()
                        number("Shutter (s)", value: Binding(
                            get: { step.captureSet.specs[index].shutterSeconds },
                            set: { updateFrame(index, shutter: $0) }))
                        number("ISO", value: Binding(
                            get: { step.captureSet.specs[index].iso },
                            set: { updateFrame(index, iso: $0) }))
                    }.padding(.vertical, 4)
                }
            }
            Section {
                DisclosureGroup("Advanced") {
                    number("Camera exposure offset (EV)", value: Binding(
                        get: { step.captureSet.perSensorEVOffsetStops[step.sensor.rawValue] ?? 0 },
                        set: {
                            var offsets = step.captureSet.perSensorEVOffsetStops
                            offsets[step.sensor.rawValue] = $0
                            replace(specs: step.captureSet.specs, generator: step.captureSet.generator, offsets: offsets)
                        }))
                    Text("Applied to shutter duration on this camera. Authored and achieved values are both retained in the capture record.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Edit Step")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Switch to Burst?", isPresented: $confirmingBurst) {
            Button("Use Burst and remove frame interval") {
                replace(specs: step.captureSet.specs, generator: step.captureSet.generator, firing: .hardwareBracket)
                step.sequentialGapSeconds = nil
            }
            Button("Keep Sequential", role: .cancel) {}
        } message: { Text("Burst fires as quickly as the camera allows. Your Sequential interval will be removed from this draft.") }
        .alert("Cannot generate series", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...9)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }.frame(minHeight: 44)
    }

    private func number(_ title: String, value: Binding<Float>) -> some View {
        number(title, value: Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }))
    }

    private func number(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            TextField(title, value: value, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
        }.frame(minHeight: 44)
    }

    private func generate(sweep: Bool) {
        guard (1...10_000).contains(frameCount), shutter.isFinite, shutter > 0,
              iso.isFinite, iso > 0, stops.isFinite, !sweep || abs(stops) * Double(frameCount) < 100 else {
            error = "Use 1–10,000 frames, positive shutter and ISO, and a finite ladder within 100 stops."
            return
        }
        let spec = CaptureSpec(shutterSeconds: shutter, iso: iso)
        let set = sweep ? CaptureSet.shutterSweep(base: spec, stopsPerRung: stops, rungs: frameCount)
            : CaptureSet.repeated(spec, count: frameCount)
        replace(specs: set.specs, generator: set.generator)
    }

    private func updateFrame(_ index: Int, shutter: Double? = nil, iso: Float? = nil) {
        var specs = step.captureSet.specs
        guard specs.indices.contains(index) else { return }
        specs[index] = CaptureSpec(shutterSeconds: shutter ?? specs[index].shutterSeconds, iso: iso ?? specs[index].iso)
        replace(specs: specs, generator: .manual)
    }

    private func replace(specs: [CaptureSpec], generator: CaptureSet.Generator,
                         offsets: [String: Double]? = nil, firing: ExecutionMode? = nil) {
        let old = step.captureSet
        step.captureSet = CaptureSetEditorDraft.replacing(old, specs: specs, generator: generator,
            firing: firing ?? old.firing, offsets: offsets ?? old.perSensorEVOffsetStops)
    }
}

/// Pure editor boundary shared by firing changes and explicit series replacement.
enum CaptureSetEditorDraft {
    static func replacing(_ old: CaptureSet, specs: [CaptureSpec], generator: CaptureSet.Generator,
                          firing: ExecutionMode, offsets: [String: Double]) -> CaptureSet {
        // Recipe-editor starters remain version zero, even when their Recipe
        // is saved. Positive versions belong to named library protocols: never
        // reinterpret those authored identifiers, even if they resemble a starter.
        // Recognize the generated title's shape independently of the current
        // mode/count: older builds may already have saved those out of sync.
        let titleParts = old.name.components(separatedBy: " · ")
        let stem = titleParts[0]
        let repeatCount = stem.hasPrefix("Repeat ") ? Int(stem.dropFirst("Repeat ".count)) : nil
        let manualCount = stem.hasPrefix("Frames ") ? Int(stem.dropFirst("Frames ".count)) : nil
        let hasGeneratedMode = titleParts.count == 2
            && ExecutionMode.allCases.contains { $0.label == titleParts[1] }
        let isGenerated = old.version == 0 && (old.name == "Single Frame"
            || (hasGeneratedMode && (stem == "Exposure Ladder" || (repeatCount ?? manualCount ?? 0) > 0)))
        var name = old.name
        if isGenerated {
            switch generator {
            case .repeated:
                name = specs.count == 1 ? "Single Frame" : "Repeat \(specs.count) · \(firing.label)"
            case .shutterSweep:
                name = "Exposure Ladder · \(firing.label)"
            case .manual:
                // Individually authored frames need not repeat or form a ladder.
                name = specs.count == 1 ? "Single Frame" : "Frames \(specs.count) · \(firing.label)"
            }
        }
        return CaptureSet(name: name, version: old.version, specs: specs, generator: generator,
                          perSensorEVOffsetStops: offsets, executionMode: firing)
    }
}
