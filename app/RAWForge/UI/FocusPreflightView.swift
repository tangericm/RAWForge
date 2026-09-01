import AVFoundation
import SwiftUI

/// Choosing focus, one sensor at a time, before the station is declared.
///
/// ## Why this is a screen and not a protocol field
///
/// Focus is the one capture parameter that cannot be authored at a desk. A
/// shutter of 1/250 s means the same thing in every room; `lensPosition = 0.62`
/// means whatever happened to be 0.62 of the way through that lens's travel,
/// which is a different distance on every sensor and describes nothing at all
/// without the scene in front of it. So the number is chosen **here**, with the
/// preview live, and the protocol stays portable.
///
/// ## Why it is per sensor
///
/// The three rear cameras do not share an actuator, a focal length, or a
/// minimum focus distance. A station spanning them has three focus decisions,
/// not one, and pretending otherwise is how a "locked" station ends up with the
/// ultra-wide focused somewhere nobody chose.
///
/// The app will map a tapped point from one sensor to another (`FocusGeometry`)
/// but never silently: the mapping ignores parallax, so it is offered as a
/// button, applied to the live preview, and left for the operator to accept or
/// move. The app is not asserting where the point landed — it is showing them.
struct FocusPreflightView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var station: StationController
    @State private var selected: SensorCapability.Sensor?
    @State private var achieved: Float?
    @State private var working = false
    @State private var sliderValue: Double = 0.5

    init(model: CaptureModel) {
        self.model = model
        self.station = model.station
    }

    /// Only the sensors this station will actually use. Offering focus on a
    /// sensor the shot list never touches is three taps spent on nothing.
    private var sensors: [SensorCapability.Sensor] {
        let planned = station.shotList.entries.map(\.sensor)
        if planned.isEmpty { return model.report?.usableSensors.map(\.sensor) ?? [] }
        var seen: [SensorCapability.Sensor] = []
        for s in planned where !seen.contains(s) { seen.append(s) }
        return seen
    }

    private var current: SensorCapability.Sensor? { selected ?? sensors.first }

    private func capability(_ s: SensorCapability.Sensor) -> SensorCapability? {
        model.report?.sensors.first { $0.sensor == s }
    }

    var body: some View {
        List {
            if sensors.isEmpty {
                Section {
                    Text("No sensor to focus. Add a set to the shot list first — focus is "
                         + "chosen for the sensors a station will actually use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if sensors.count > 1 { sensorSection }
                previewSection
                if let s = current { intentSection(s); statusSection(s) }
                summarySection
            }
        }
        .navigationTitle("Focus")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bringUp(current) }
        .onDisappear { model.rig.stopSession() }
    }

    // MARK: - Which sensor is being focused

    private var sensorSection: some View {
        Section {
            Picker("Sensor", selection: Binding(
                get: { current ?? sensors[0] },
                set: { selected = $0; bringUp($0) }
            )) {
                ForEach(sensors, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Each sensor is focused separately. They do not share a lens, so a setting "
                 + "on one says nothing about the others.")
        }
    }

    // MARK: - The preview, which is the whole point

    private var previewSection: some View {
        Section {
            ZStack {
                // Visibly bounded with nothing in it, for the same reason
                // `ViewfinderPanel` is: black on black reads as a broken app
                // rather than as a viewfinder still coming up, and this screen
                // spends its first second in exactly that state on every
                // sensor change.
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1))
                CameraPreview(
                    session: model.rig.session,
                    onTapDevicePoint: { p in
                        guard let s = current else { return }
                        station.focusPlan[s] = .point(x: Double(p.x), y: Double(p.y))
                        apply(s)
                    },
                    indicatorDevicePoint: current.flatMap { station.focusPlan[$0].pointOfInterest })
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            // Capped, and the cap is the trade. At its natural 4:3 across the
            // full width the preview filled the screen and pushed the mode
            // picker — the actual decision here — below the fold, so the
            // operator would scroll past the thing they came to set. Narrower
            // and whole beats wider and cropped: a framing aid that hides part
            // of the frame would have them aiming at edges that are not the
            // edges being captured.
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
        } footer: {
            Text("Tap the subject to focus there. Framing only — never the payload.")
        }
    }

    // MARK: - How this sensor decides

    @ViewBuilder private func intentSection(_ s: SensorCapability.Sensor) -> some View {
        let cap = capability(s)
        let intent = station.focusPlan[s]

        Section {
            Picker("Mode", selection: Binding(
                get: { modeIndex(intent) },
                set: { setMode($0, for: s) }
            )) {
                Text("Automatic").tag(0)
                Text("Point").tag(1)
                Text("Manual").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(working)

            if case .manual = intent {
                if cap?.supportsCustomLensPosition == false {
                    Label("This sensor cannot be given a lens position. It will autofocus "
                          + "and lock instead, and the frames will say so.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $sliderValue, in: 0...1) { editing in
                            if !editing { station.focusPlan[s] = .manual(lensPosition: sliderValue) }
                        }
                        .onChange(of: sliderValue) { _, v in
                            station.focusPlan[s] = .manual(lensPosition: v)
                            model.rig.previewLensPosition(Float(v))
                        }
                        HStack {
                            Text("near").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.3f", sliderValue))
                                .font(.caption).monospaced()
                            Spacer()
                            Text("far").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("\(s.rawValue) focus")
        } footer: {
            Text(explanation(intent))
        }
    }

    private func explanation(_ intent: FocusPlan.Intent) -> String {
        switch intent {
        case .automatic:
            return "Autofocus runs when this sensor comes up at the pose, then locks and is "
                 + "recorded. Every frame of the set shares it."
        case .point:
            return "Autofocus runs at the point you tapped, then locks. Moving the phone "
                 + "after this moves what is at that point."
        case .manual:
            return "The lens goes straight here, with no autofocus at all. The number is a "
                 + "position along this lens's travel, not a distance — it is meaningful "
                 + "because you can see the result, and meaningless on any other sensor."
        }
    }

    // MARK: - What this sensor can actually do, and what the others chose

    @ViewBuilder private func statusSection(_ s: SensorCapability.Sensor) -> some View {
        let cap = capability(s)
        Section {
            if let mm = cap?.minimumFocusDistanceMillimetres {
                LabeledContent("Closest focus", value: mm >= 1000
                               ? String(format: "%.2f m", Double(mm) / 1000)
                               : "\(mm) mm")
            }
            if let fov = cap?.horizontalFieldOfViewDegrees {
                LabeledContent("Field of view", value: String(format: "%.0f°", fov))
            }
            if let a = achieved {
                LabeledContent("Lens is at", value: String(format: "%.3f", a))
            }
            if cap?.canHoldFocus == false {
                Label("This sensor cannot hold focus. It will shoot anyway, and every frame "
                      + "will record that focus was not locked.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            mappedSeed(for: s)
        } header: {
            Text("This sensor")
        }
    }

    /// The one place the cross-sensor mapping is offered — as a button, never
    /// applied behind the operator's back.
    @ViewBuilder private func mappedSeed(for s: SensorCapability.Sensor) -> some View {
        if case .automatic = station.focusPlan[s],
           let source = sensors.first(where: { $0 != s && station.focusPlan[$0].pointOfInterest != nil }),
           let from = capability(source)?.horizontalFieldOfViewDegrees,
           let to = capability(s)?.horizontalFieldOfViewDegrees,
           let p = station.focusPlan[source].pointOfInterest {
            let mapped = FocusGeometry.map(point: p, fromFieldOfView: from, toFieldOfView: to)
            switch mapped {
            case .inside(let q):
                Button {
                    station.focusPlan[s] = .point(x: Double(q.x), y: Double(q.y))
                    apply(s)
                } label: {
                    Label("Put the point from \(source.rawValue) here",
                          systemImage: "arrow.turn.down.right")
                }
                Text("Computed from the two fields of view. It ignores parallax — about "
                     + "half a degree at a metre, two at thirty centimetres — so check it "
                     + "on the preview and move it if it missed.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .outsideFrame:
                Label("What \(source.rawValue) is focused on is outside \(s.rawValue)'s frame.",
                      systemImage: "rectangle.dashed")
                    .font(.caption).foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }
        }
    }

    private var summarySection: some View {
        Section {
            ForEach(sensors, id: \.self) { s in
                LabeledContent(s.rawValue) {
                    Text(describe(station.focusPlan[s]))
                        .foregroundStyle(station.focusPlan[s] == .automatic ? .secondary : .primary)
                }
                .font(.caption)
            }
        } header: {
            Text("This station")
        } footer: {
            Text("Focus belongs to the station, not to a protocol — a lens position means "
                 + "nothing away from what it was focused on. It is cleared when the next "
                 + "station is declared.")
        }
    }

    private func describe(_ i: FocusPlan.Intent) -> String {
        switch i {
        case .automatic:            return "automatic"
        case .point(let x, let y):  return String(format: "point %.2f, %.2f", x, y)
        case .manual(let p):        return String(format: "manual %.3f", p)
        }
    }

    // MARK: - Driving the device

    private func modeIndex(_ i: FocusPlan.Intent) -> Int {
        switch i {
        case .automatic: return 0
        case .point:     return 1
        case .manual:    return 2
        }
    }

    private func setMode(_ index: Int, for s: SensorCapability.Sensor) {
        switch index {
        case 1:
            // Point mode with nothing tapped yet aims at the centre, which is
            // where autofocus would have looked anyway — so the mode change
            // alone never moves focus somewhere unexpected.
            if station.focusPlan[s].pointOfInterest == nil {
                station.focusPlan[s] = .point(x: 0.5, y: 0.5)
            }
        case 2:
            station.focusPlan[s] = .manual(lensPosition: sliderValue)
        default:
            station.focusPlan[s] = .automatic
        }
        apply(s)
    }

    private func bringUp(_ s: SensorCapability.Sensor?) {
        guard let s else { return }
        achieved = nil
        if case let .manual(p) = station.focusPlan[s] { sliderValue = p }
        Task {
            try? await model.rig.configure(s)
            await model.rig.startSessionAndWait()
            apply(s)
        }
    }

    /// Applies the current intent to the live device so the preview shows it.
    /// The result is thrown away deliberately — what gets recorded is the lock
    /// taken at the pose, not this rehearsal.
    private func apply(_ s: SensorCapability.Sensor) {
        guard !working else { return }
        working = true
        Task {
            let focus = await model.rig.applyFocus(
                FocusResolution(intent: station.focusPlan[s],
                                point: station.focusPlan[s].pointOfInterest))
            achieved = focus.lensPosition
            if case .automatic = station.focusPlan[s], let p = focus.lensPosition {
                sliderValue = Double(p)
            }
            working = false
        }
    }
}
