import SwiftUI

/// Authoring a capture protocol, on device.
///
/// #8's amendment allows this mid-shoot, because requiring a protocol be
/// written ahead of time is a speed bump on the shoot-look-tweak loop that an
/// instrument for designing capture experiments exists to serve. The provenance
/// requirement is met a different way: the version auto-bumps on every save and
/// the full definition is inlined into the session, so a reader holding only the
/// session knows exactly what produced it.
///
/// Loading an existing protocol into the editor is therefore not an edit in
/// place — saving writes the **next version**, and the one already shot is
/// still the one the sessions that used it refer to.
struct ProtocolEditorView: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSweep = true
    @State private var rungs = 7
    @State private var stopsPerRung = 1.0
    @State private var shutter = 1.0 / 125
    @State private var iso: Float = 100
    @State private var saveError: String?
    @State private var pendingDelete: String?

    /// Standard stops, so a ladder centre is picked rather than typed.
    private let shutters: [(String, Double)] = [
        ("1/2000", 1.0/2000), ("1/1000", 1.0/1000), ("1/500", 1.0/500),
        ("1/250", 1.0/250), ("1/125", 1.0/125), ("1/60", 1.0/60),
        ("1/30", 1.0/30), ("1/15", 1.0/15), ("1/8", 1.0/8),
        ("1/4", 1.0/4), ("1/2", 1.0/2), ("1s", 1.0),
    ]

    /// What would be saved, rendered live. A sweep is a generator and these are
    /// the rungs it actually produces — the point of showing them is that a
    /// ladder's ends are easy to get wrong in the head.
    private var draft: CaptureSet {
        let base = CaptureSpec(shutterSeconds: shutter, iso: iso)
        let set: CaptureSet = isSweep
            ? .shutterSweep(base: base, stopsPerRung: stopsPerRung, rungs: rungs)
            : .repeated(base, count: rungs)
        return CaptureSet(name: set.name, version: set.version, specs: set.specs,
                          generator: set.generator, perSensorEVOffsetStops: model.evOffsets)
    }

    var body: some View {
        NavigationStack {
            List {
                definitionSection
                offsetSection
                rungsSection
                if !model.savedProtocols.isEmpty { librarySection }
                presetSection
            }
            .navigationTitle("Protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this protocol?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                if let n = pendingDelete {
                    Button("Delete \(n)", role: .destructive) {
                        ProtocolLibrary.delete(named: n)
                        model.refreshProtocols()
                        logInfo(.flow, "protocol \(n) deleted")
                        pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Sessions already shot under it are unaffected — they carry the full "
                     + "definition inline, not a reference to this file.")
            }
        }
    }

    // MARK: - Sections

    private var definitionSection: some View {
        Section("Definition") {
            TextField("name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let existing = ProtocolLibrary.load(named: name.trimmingCharacters(in: .whitespaces)) {
                Label("Saving writes v\(existing.version + 1) — v\(existing.version) stays as shot.",
                      systemImage: "arrow.up.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let e = saveError {
                Text(e).font(.caption).foregroundStyle(.red)
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
                if let w = isoWarning(base: lo) {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    /// One definition across sensors, shifted per sensor. Useful ISO ceilings
    /// differ enough between 1x, 0.5x and tele that the same ladder may not
    /// suit all three.
    @ViewBuilder private var offsetSection: some View {
        if let report = model.report, report.usableSensors.count > 1 {
            Section("Per-sensor EV offset") {
                ForEach(report.usableSensors) { cap in
                    let key = cap.sensor.rawValue
                    Stepper(value: Binding(
                        get: { model.evOffsets[key] ?? 0 },
                        set: { model.evOffsets[key] = $0 == 0 ? nil : $0 }
                    ), in: -3...3, step: 0.5) {
                        LabeledContent(key, value: String(format: "%+.1f stop", model.evOffsets[key] ?? 0))
                    }
                }
                Text("The sensors are not interchangeable. The authored ladder is stored "
                     + "once; each sensor shoots it shifted by its own offset.")
                    .font(.caption2).foregroundStyle(.secondary)
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
                    Text("… \(checked.kept.count - 12) more").font(.caption).foregroundStyle(.secondary)
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
                    Label("\(checked.kept.count) frames exceeds \(cap.sensor.rawValue)'s hardware "
                          + "bracket max of \(cap.maxBracketedCapturePhotoCount) — this set has to "
                          + "run sequentially.", systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var librarySection: some View {
        Section("Saved") {
            ForEach(model.savedProtocols, id: \.name) { p in
                Button { load(p) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(p.name) v\(p.version)").font(.callout)
                            Text(p.generator.describe).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = p.name }
                }
            }
        }
    }

    private var presetSection: some View {
        Section("Start from") {
            ForEach(ProtocolLibrary.presets(), id: \.0) { preset in
                Button(preset.0) { load(preset.1, named: preset.0) }
                    .font(.callout)
            }
            Text("Examples, not constraints — nothing about these is privileged once saved.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func isoWarning(base: Float) -> String? {
        guard iso > base * 8.5 else { return nil }
        return String(format: "ISO %.0f is past ~8.5× the base of %.0f — beyond that the gain "
                      + "is digital, not analogue. Bracket with shutter instead.", iso, base)
    }

    /// Pulls a stored set back into the controls. Only a generator-produced set
    /// can be reconstructed exactly; a hand-built one is loaded as its rungs and
    /// says so rather than pretending the sliders describe it.
    private func load(_ set: CaptureSet, named override: String? = nil) {
        name = override ?? set.name
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
            saveError = "This set was not built from a generator, so the controls above "
                + "approximate it rather than reproduce it."
        }
        model.evOffsets = set.perSensorEVOffsetStops
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let stored = try ProtocolLibrary.save(draft, as: trimmed)
            model.refreshProtocols()
            model.selectedProtocol = stored
            model.builderProtocolName = stored.name
            logInfo(.flow, "protocol \(stored.name) saved as v\(stored.version) — "
                    + "\(stored.specs.count) rung(s), \(stored.generator.describe)")
            dismiss()
        } catch {
            saveError = "Could not save — \(error.localizedDescription)"
            logFailure(.store, "saving protocol \(trimmed)", error)
        }
    }
}
