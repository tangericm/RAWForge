import SwiftUI

/// A protocol picker plus sensor selection — the two things every bench run
/// needs and neither of which it may guess at.
private struct RunSubject: View {
    @ObservedObject var model: CaptureModel
    @State private var showingEditor = false

    var body: some View {
        Section("Protocol") {
            Picker("In force", selection: Binding(
                get: { model.selectedProtocol?.name ?? "" },
                set: { model.selectedProtocol = $0.isEmpty ? nil : ProtocolLibrary.load(named: $0) })
            ) {
                Text("— none chosen —").tag("")
                ForEach(model.savedProtocols, id: \.name) { p in
                    Text("\(p.name) v\(p.version)").tag(p.name)
                }
            }
            if let p = model.selectedProtocol {
                Text("\(p.specs.count) rung(s) · \(p.generator.describe)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // No silent default (#8): a run is never shot under a protocol
                // nobody chose.
                Label("A run needs a named protocol. Without one there is nothing to "
                      + "re-run identically later.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            NavigationLink {
                ProtocolLibraryView(model: model)
            } label: {
                Label("Manage protocols", systemImage: "square.and.pencil")
            }
        }

        if let report = model.report, report.canCapture {
            Section("Sensors") {
                ForEach(report.usableSensors) { cap in
                    Toggle(cap.sensor.rawValue, isOn: Binding(
                        get: { model.selectedSensors.contains(cap.sensor) },
                        set: { on in
                            if on { model.selectedSensors.insert(cap.sensor) }
                            else { model.selectedSensors.remove(cap.sensor) }
                        }))
                }
            }
        }
    }
}

/// The dark-frame run.
///
/// This is the one place in the app that forms a verdict and refuses. Everywhere
/// else the app cannot know better than the photographer, who can see the scene.
/// Here it can: a capped lens has an unambiguous signature, and there is no
/// legitimate reason to record a bright frame as a dark reference.
struct CalibrationView: View {
    @ObservedObject var model: CaptureModel

    private var plannedFrames: Int {
        (model.currentSet?.specs.count ?? 0)
            * max(1, model.selectedSensors.count) * model.darkRepeats
    }

    var body: some View {
        List {
            Section {
                Label("Cap the lens before starting.", systemImage: "circle.slash")
                    .font(.callout).bold()
                Text("A frame that is not actually dark is not written as a dark frame — "
                     + "a bad dark reference looks like data, is wrong, and silently corrupts "
                     + "every photometric claim calibrated against it. The refusal is still "
                     + "logged, so the record can tell \"not shot\" from \"shot and refused\".")
                    .font(.caption).foregroundStyle(.secondary)
            }

            RunSubject(model: model)

            Section("Repeats") {
                Stepper(value: $model.darkRepeats, in: 1...32) {
                    LabeledContent("Frames per setting", value: "\(model.darkRepeats)")
                }
                Text("Averaging N frames cuts noise by √N; black-level estimation typically "
                     + "wants 8–16 per setting.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                if plannedFrames > 0 {
                    LabeledContent("Planned", value: "\(plannedFrames) frames")
                    LabeledContent("Worst case", value: SessionEstimate.formatBytes(
                        Int64(plannedFrames) * SessionEstimate.worstCaseFrameBytes))
                }
                Button {
                    Task { await model.runDarkCalibration() }
                } label: {
                    Label("Run calibration", systemImage: "play.fill")
                }
                .disabled(model.busy || model.currentSet == nil || model.selectedSensors.isEmpty)
                if model.busy {
                    HStack { ProgressView(); Text(model.darkProgress).font(.caption2) }
                }
            } footer: {
                Text("A setting that fails is abandoned on its own — the rest of the run "
                     + "continues, because none of it depends on a pose that has since moved. "
                     + "If the very first setting fails the cap is off, and the run stops there "
                     + "rather than grinding through hundreds of refusals.")
            }

            if !model.status.isEmpty {
                Section("Result") { Text(model.status).font(.caption) }
            }
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The instrument checks: runs whose output is a *finding about the app*, not a
/// scene. Kept apart from capture because a station shot to answer a question
/// about the pipeline is not a station of data.
struct InstrumentChecksView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        List {
            if model.session == nil {
                Section {
                    Label("These checks write into a session. Open one first.",
                          systemImage: "folder.badge.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open session") { model.openSession() }
                }
            }

            RunSubject(model: model)

            Section {
                Button {
                    Task { await model.runWhiteBalanceProbe() }
                } label: {
                    Label("White-balance pixel path", systemImage: "drop.halffull")
                }
                .disabled(model.session == nil || model.busy || model.currentSet == nil)
            } header: {
                Text("Does a locked white balance reach the pixels?")
            } footer: {
                Text("Shoots the whole set twice from one pose under two deliberately opposite "
                     + "gain settings. Whether the Bayer payload changed — or only the "
                     + "AsShotNeutral tag did — is decided off device, where the pixels can "
                     + "actually be compared.")
            }

            Section {
                Button {
                    Task { await model.runZoomProbe() }
                } label: {
                    Label("Zoom enforcement", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .disabled(model.session == nil || model.busy)
                if let z = model.zoomProbe {
                    Text(z.verdict).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("What happens at a zoom factor other than 1.0")
            } footer: {
                Text("Bayer capture requires a zoom factor of exactly 1.0, and the platform "
                     + "enforces it by killing the process rather than returning an error. "
                     + "The app refuses before that call, so this check confirms the guard is "
                     + "still needed. Each stage is flushed to disk as it runs — if the process "
                     + "does die, the record of how far it got survives.")
            }

            if model.busy {
                Section { HStack { ProgressView(); Text(model.progress).font(.caption2) } }
            }
            if !model.status.isEmpty {
                Section("Result") { Text(model.status).font(.caption) }
            }
        }
        .navigationTitle("Checks")
        .navigationBarTitleDisplayMode(.inline)
    }
}
