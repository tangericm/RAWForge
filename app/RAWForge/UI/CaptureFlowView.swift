import SwiftUI

/// The capture screen: a session, a station, a shot list, and one action
/// available at a time.
///
/// The phase banner is the whole interface in one line. Every wait it shows is
/// a wait the operator cannot skip — stillness has no override, and nothing
/// fires before the exposure has settled — so telling them *why* they are
/// waiting is the difference between an instrument and a frozen app.
struct CaptureFlowView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        List {
            phaseBanner
            if model.phase == .noSession { sessionSection }
            else {
                Section { ViewfinderPanel(model: model) }
                stationSection
                StationPlanView(model: model)
                buildSection
            }
            if let f = model.lastFault { faultSection(f) }
        }
        .navigationTitle("Capture")
        .onAppear { model.startFlow() }
    }

    private var phaseBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.phase.title).font(.headline)
                    Spacer()
                    if model.busy { ProgressView() }
                }
                Text(model.phase.note).font(.caption).foregroundStyle(.secondary)
                if !model.status.isEmpty {
                    Text(model.status).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            if model.report?.canCapture == true {
                Button("Open session") { model.openSession(); model.startFlow() }
            } else {
                Text("No sensor on this device delivers Bayer RAW — capture refused.")
                    .font(.footnote)
            }
        }
    }

    private var stationSection: some View {
        Section("Station") {
            if let s = model.session {
                LabeledContent("Session", value: s.sessionId)
                if let cal = s.calibrationSessionId {
                    Text("calibration \(cal), \(Int((s.calibrationAgeSeconds ?? 0) / 60)) min old")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("no calibration referenced — black level is the file's assertion, unmeasured")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if model.phase == .sessionOpen {
                TextField("Pose intent", text: $model.poseIntent).font(.callout)
                Button("Declare station") { model.declareStation() }
                    .disabled(model.shotList.entries.isEmpty)
                if model.shotList.entries.isEmpty {
                    Text("build a shot list first — a station with nothing to shoot is not a station")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Button("Close session") { model.closeSession() }
            } else {
                Button("Begin next capture set") { Task { await model.beginNextSet() } }
                    .disabled(!model.canBeginSet || model.busy)
                Button("Close station") { model.closeStation() }
                    .disabled(!model.canCloseStation || model.busy)
                if !model.shotList.canClose && model.phase == .stationOpen {
                    Text("\(model.shotList.remaining) set(s) left — a station completes or never existed")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Superseded by StationPlanView's timeline, kept for the compact count.
    private var shotListSection: some View {
        Section("Shot list · \(model.shotList.cursor)/\(model.shotList.entries.count)") {
            if model.shotList.entries.isEmpty {
                Text("empty").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(model.shotList.entries) { e in
                HStack {
                    Image(systemName: e.index < model.shotList.cursor ? "checkmark.circle.fill"
                          : e.index == model.shotList.cursor ? "arrowtriangle.right.fill" : "circle")
                        .foregroundStyle(e.index < model.shotList.cursor ? .green
                                         : e.index == model.shotList.cursor ? .accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text(e.label).font(.callout)
                        Text("\(e.frameCount) frames").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .opacity(e.index < model.shotList.cursor ? 0.45 : 1)
            }
            if !model.shotList.entries.isEmpty {
                Text("\(model.shotList.totalFrames) frames total · "
                     + "~\(model.shotList.totalFrames * 10) MB")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var buildSection: some View {
        Section("Add to shot list") {
            if model.phase != .sessionOpen {
                Text("the shot list is fixed once a station is declared")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let report = model.report {
                Picker("Sensor", selection: $model.builderSensor) {
                    ForEach(report.usableSensors) { Text($0.sensor.rawValue).tag($0.sensor) }
                }
                Picker("Protocol", selection: $model.builderProtocolName) {
                    Text("— none saved —").tag("")
                    ForEach(model.savedProtocols, id: \.name) { Text("\($0.name) v\($0.version)").tag($0.name) }
                }
                Button("Add") { model.addToShotList() }
                    .disabled(model.builderProtocolName.isEmpty)
                Toggle("Group by sensor", isOn: $model.groupShotListBySensor)
                if !model.shotList.entries.isEmpty {
                    Button("Clear shot list", role: .destructive) { model.clearShotList() }
                }
                if model.savedProtocols.isEmpty {
                    Text("no protocols saved — author one in Diagnostics first")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func faultSection(_ f: StationFault) -> some View {
        Section("Last fault") {
            Text(f.operatorNote).font(.callout).foregroundStyle(.red)
            Text("The station's frames were deleted. Stations already banked survive, "
                 + "so there is no partial state to interpret later.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
