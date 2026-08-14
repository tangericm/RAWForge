import SwiftUI

/// What this phone has actually been measured to do, and what is still borrowed.
///
/// The screen exists because the alternative is worse than a gap: before this,
/// every timing the plan showed came from one iPhone 15 Pro and was presented
/// with no indication of that. A borrowed figure is a reasonable guess; a
/// borrowed figure that looks measured is a claim the app cannot support.
struct DeviceProfileView: View {
    @ObservedObject var model: CaptureModel
    @State private var profile = DeviceProfile.active
    @State private var running = false
    @State private var step: DeviceCharacterisation.Step?
    @State private var error: String?

    var body: some View {
        List {
            statusSection
            readingsSection
            if profile.isCharacterised { forgetSection }
        }
        .navigationTitle("This device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { profile = DeviceProfile.active }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if profile.isCharacterised {
                    Label("Measured on this device", systemImage: "checkmark.seal.fill")
                        .font(.callout).bold().foregroundStyle(.green)
                    if let at = profile.measuredAt {
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Not yet characterised", systemImage: "questionmark.circle.fill")
                        .font(.callout).bold().foregroundStyle(.orange)
                    Text("Timing and size estimates are borrowed from a reference "
                         + "\(DeviceProfile.referenceDevice). They will be wrong here by an "
                         + "unknown amount — which is worse than being absent, because a plan "
                         + "reads as authoritative.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let e = error {
                    Text(e).font(.caption2).foregroundStyle(.red)
                }

                if running {
                    HStack(spacing: 8) {
                        ProgressView()
                        if let s = step {
                            Text("\(s.label) — \(s.index) of \(s.total)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        Task { await characterise() }
                    } label: {
                        Label(profile.isCharacterised ? "Measure again" : "Measure this device",
                              systemImage: "ruler")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.report?.canCapture != true || model.busy)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text("Captures around twenty frames and writes none of them — a characterisation "
                 + "is the app measuring itself, not data. It does not need a capped lens; "
                 + "none of these timings depend on what the lens sees.")
        }
    }

    // MARK: - Readings

    private var readingsSection: some View {
        Section {
            ForEach(Array(profile.readings.enumerated()), id: \.offset) { _, item in
                readingRow(item.name, item.reading)
            }
        } header: {
            Text("Readings")
        } footer: {
            Text("The settle is permanently borrowed. "
                 + DeviceProfile.stillnessIsNotMeasurable
                 + " The largest frame is learned from real captures instead, because a DNG's "
                 + "size depends on what was in front of the lens.")
        }
    }

    private func readingRow(_ name: String, _ r: Reading) -> some View {
        HStack(alignment: .top) {
            Image(systemName: r.isMeasured ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(r.isMeasured ? .green : .secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                Text(format(name, r.value)).font(.caption2).monospaced()
                    .foregroundStyle(.secondary)
                if let n = r.sampleCount, let spread = r.spread, r.isMeasured {
                    Text(spread > 0
                         ? "\(n) sample(s) · spread \(format(name, spread))"
                         : "\(n) sample(s)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !r.isMeasured {
                Text("borrowed").font(.system(size: 9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Bytes and seconds are both `Double` in a `Reading`; the name is what
    /// tells them apart, which is ugly but keeps the stored shape flat.
    private func format(_ name: String, _ value: Double) -> String {
        name.contains("frame size") || name.contains("frame seen")
            ? SessionEstimate.formatBytes(Int64(value))
            : SessionEstimate.formatDuration(value)
    }

    private var forgetSection: some View {
        Section {
            Button("Forget these measurements", role: .destructive) {
                DeviceProfile.forget()
                profile = DeviceProfile.active
            }
        } footer: {
            Text("Estimates fall back to the reference device and are labelled borrowed again.")
        }
    }

    // MARK: - Running

    private func characterise() async {
        guard let report = model.report else { return }
        running = true
        error = nil
        defer { running = false; step = nil }
        do {
            let measured = try await DeviceCharacterisation.run(
                rig: model.rig, report: report, onStep: { step = $0 })
            try measured.save()
            profile = measured
            model.startFraming()
        } catch {
            self.error = "Could not finish — \(error)"
            logFailure(.probe, "characterisation", error)
            model.rig.stopSession()
        }
    }
}
