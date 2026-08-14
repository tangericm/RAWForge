import SwiftUI

/// Authoring one capture protocol, and only that.
///
/// #8's amendment allows this on device, mid-shoot, because requiring a protocol
/// be written ahead of time is a speed bump on the shoot-look-tweak loop that an
/// instrument for designing capture experiments exists to serve. The provenance
/// requirement is met a different way: the version auto-bumps on every save and
/// the full definition is inlined into the session, so a reader holding only the
/// session knows exactly what produced it.
///
/// Editing an existing protocol is therefore not an edit in place — saving
/// writes the **next version**, and the one already shot is still what the
/// sessions that used it refer to.
struct ProtocolEditorView: View {
    @ObservedObject var model: CaptureModel
    /// Nil to author a new one; otherwise the definition to start from.
    let editing: CaptureSet?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSweep = true
    @State private var rungs = 7
    @State private var stopsPerRung = 1.0
    @State private var shutter = 1.0 / 125
    @State private var iso: Float = 100
    @State private var evOffsets: [String: Double] = [:]
    @State private var notice: String?
    @State private var loaded = false

    /// Standard stops, so a ladder centre is picked rather than typed.
    private let shutters: [(String, Double)] = [
        ("1/2000", 1.0/2000), ("1/1000", 1.0/1000), ("1/500", 1.0/500),
        ("1/250", 1.0/250), ("1/125", 1.0/125), ("1/60", 1.0/60),
        ("1/30", 1.0/30), ("1/15", 1.0/15), ("1/8", 1.0/8),
        ("1/4", 1.0/4), ("1/2", 1.0/2), ("1s", 1.0),
    ]

    /// What would be saved, rendered live. A sweep is a generator and these are
    /// the rungs it produces — a ladder's ends are easy to get wrong in the head.
    private var draft: CaptureSet {
        let base = CaptureSpec(shutterSeconds: shutter, iso: iso)
        let set: CaptureSet = isSweep
            ? .shutterSweep(base: base, stopsPerRung: stopsPerRung, rungs: rungs)
            : .repeated(base, count: rungs)
        return CaptureSet(name: set.name, version: set.version, specs: set.specs,
                          generator: set.generator, perSensorEVOffsetStops: evOffsets)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            List {
                definitionSection
                offsetSection
                rungsSection
            }
            // A preset arrives as `editing` too, but it is not in the library
            // yet — calling that "Edit" would claim something is being revised
            // that does not exist.
            .navigationTitle(ProtocolLibrary.load(named: trimmedName) == nil
                             ? "New protocol" : "Edit protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.bold().disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { if !loaded { load(); loaded = true } }
        }
    }

    // MARK: - Sections

    private var definitionSection: some View {
        Section {
            TextField("name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let existing = ProtocolLibrary.load(named: trimmedName) {
                Label("Saving writes v\(existing.version + 1). v\(existing.version) stays as shot.",
                      systemImage: "arrow.up.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice).font(.caption2).foregroundStyle(.orange)
            }
            Picker("Shape", selection: $isSweep) {
                Text("Sweep").tag(true)
                Text("Repeat").tag(false)
            }
            .pickerStyle(.segmented)
            Stepper(value: $rungs, in: 1...512) {
                LabeledContent(isSweep ? "Rungs" : "Frames", value: "\(rungs)")
            }
            if isSweep {
                Stepper(value: $stopsPerRung, in: 0.25...3, step: 0.25) {
                    LabeledContent("Stops apart", value: String(format: "%.2f", stopsPerRung))
                }
            }
            Picker(isSweep ? "Centre shutter" : "Shutter", selection: $shutter) {
                ForEach(shutters, id: \.1) { Text($0.0).tag($0.1) }
            }
            if let cap = model.report?.usableSensors.first, let lo = cap.minISO, let hi = cap.maxISO {
                Stepper(value: $iso, in: lo...hi, step: max(1, lo)) {
                    LabeledContent("ISO", value: String(format: "%.0f", iso))
                }
                if iso > lo * 8.5 {
                    Label(String(format: "Past roughly %.0f the gain is digital rather than "
                                 + "analogue. Bracket with shutter instead.", lo * 8.5),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Definition")
        }
    }

    /// One definition across sensors, shifted per sensor. Useful ISO ceilings
    /// differ enough between 1x, 0.5x and tele that the same ladder may not
    /// suit all three.
    @ViewBuilder private var offsetSection: some View {
        if let report = model.report, report.usableSensors.count > 1 {
            Section {
                ForEach(report.usableSensors) { cap in
                    let key = cap.sensor.rawValue
                    Stepper(value: Binding(
                        get: { evOffsets[key] ?? 0 },
                        set: { evOffsets[key] = $0 == 0 ? nil : $0 }
                    ), in: -3...3, step: 0.5) {
                        LabeledContent(key, value: String(format: "%+.1f stop", evOffsets[key] ?? 0))
                    }
                }
            } header: {
                Text("Per-sensor offset")
            } footer: {
                Text("The sensors are not interchangeable. The ladder is stored once; each "
                     + "sensor shoots it shifted by its own offset.")
            }
        }
    }

    private var rungsSection: some View {
        Section("Rendered · \(draft.specs.count) frames") {
            Text(draft.generator.describe).font(.caption).foregroundStyle(.secondary)
            if let cap = model.report?.usableSensors.first {
                let checked = draft.validated(against: cap)
                ForEach(Array(checked.kept.prefix(12).enumerated()), id: \.offset) { i, s in
                    Text("\(i + 1). \(s.shutterLabel) · ISO \(Int(s.iso))")
                        .font(.caption).monospaced()
                }
                if checked.kept.count > 12 {
                    Text("… \(checked.kept.count - 12) more")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Dropped, never clamped — a clamped rung reads back as though
                // it were the request, which is the inference this app exists
                // to eliminate.
                ForEach(Array(checked.dropped.enumerated()), id: \.offset) { _, d in
                    Label("\(d.spec.shutterLabel) ISO \(Int(d.spec.iso)) — \(d.reason)",
                          systemImage: "minus.circle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if checked.kept.count > cap.maxBracketedCapturePhotoCount {
                    let ceiling = cap.maxBracketedCapturePhotoCount
                    let requests = SessionEstimate.requestCount(frames: checked.kept.count,
                                                                ceiling: ceiling)
                    Label("Past \(cap.sensor.rawValue)'s hardware bracket ceiling of \(ceiling), "
                          + "so this fires as \(requests) requests. Frames within a request are "
                          + "\(Int(DeviceProfile.active.sensorFramePeriod.value * 1000)) ms apart; each seam "
                          + "between requests costs about "
                          + "\(Int(DeviceProfile.active.bracketSeam.value * 1000)) ms.",
                          systemImage: "rectangle.split.3x1")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Loading and saving

    /// Only a generator-produced set can be reconstructed exactly. A hand-built
    /// one is loaded as its rungs and says so rather than pretending the
    /// controls describe it.
    private func load() {
        guard let set = editing else { return }
        name = set.name
        evOffsets = set.perSensorEVOffsetStops
        switch set.generator {
        case .shutterSweep(let base, let stops, let n):
            isSweep = true; shutter = base.shutterSeconds; iso = base.iso
            stopsPerRung = stops; rungs = n
        case .repeated(let spec, let n):
            isSweep = false; shutter = spec.shutterSeconds; iso = spec.iso; rungs = n
        case .manual:
            isSweep = false
            shutter = set.specs.first?.shutterSeconds ?? shutter
            iso = set.specs.first?.iso ?? iso
            rungs = set.specs.count
            notice = "This set was not built from a generator, so the controls above "
                + "approximate it rather than reproduce it."
        }
    }

    private func save() {
        do {
            let stored = try ProtocolLibrary.save(draft, as: trimmedName)
            model.refreshProtocols()
            logInfo(.flow, "protocol \(stored.name) saved as v\(stored.version) — "
                    + "\(stored.specs.count) rung(s), \(stored.generator.describe)")
            dismiss()
        } catch {
            notice = "Could not save — \(error.localizedDescription)"
            logFailure(.store, "saving protocol \(trimmedName)", error)
        }
    }
}
