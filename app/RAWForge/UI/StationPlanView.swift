import SwiftUI

/// The shot list as a timeline, with what it will cost.
///
/// Every number here is measured on this device rather than assumed — the
/// 33.4 ms frame period, the 233 ms sequential overhead, the ~400 ms sensor
/// swap, 10 MB a frame. An estimate built from guesses is worse than none,
/// because it reads as authoritative while being wrong, so where a figure is a
/// worst case it is labelled as one.
struct StationPlanView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var station: StationController
    @State private var calibration: EstimateCalibration = .identity

    init(model: CaptureModel) {
        self.model = model
        self.station = model.station
    }

    private var estimate: SessionEstimate {
        SessionEstimate.forShotList(station.shotList.entries,
                                    minimumGap: station.minimumGap,
                                    bracketCeiling: station.bracketCeiling)
    }

    var body: some View {
        let e = estimate
        return Group {
            if station.shotList.entries.isEmpty {
                Section { Text("Nothing planned yet.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Section("Where the time goes") {
                    TimeBudgetBar(breakdown: e.breakdown)
                        .padding(.vertical, 4)
                    // Named for what this station actually contains: a phone
                    // with one rear camera never swaps, and saying it does
                    // would be the sort of small lie this app avoids.
                    Text(String(format: "%.0f%% of this station is not shooting — %@. "
                                + "The pose is held for all of it.",
                                100 * e.breakdown.notShooting,
                                e.breakdown.overheadNames))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Timeline") {
                    StationTimeline(entries: station.shotList.entries,
                                    cursor: station.shotList.cursor,
                                    estimate: e,
                                    minimumGap: station.minimumGap,
                                    bracketCeiling: station.bracketCeiling)
                        .padding(.vertical, 4)
                }
                Section("Totals") { budget(e) }
            }
        }
        // Reading every recent station's log to derive the correction ratio is
        // file work, so it happens once off the render path.
        .task { calibration = EstimateCalibration.fromRecentStations() }
    }

    private func budget(_ e: SessionEstimate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            line("Frames", "\(e.frameCount) across \(e.sensorSwaps) sensor(s)")
            line("Exposure", SessionEstimate.formatDuration(e.exposureSeconds))
            line("Overhead", SessionEstimate.formatDuration(e.overheadSeconds)
                 + " (" + e.breakdown.overheadNames + ")")
            if e.bracketSeams > 0 {
                // Named separately because it is the one cost that is not
                // obvious from the frame count: it appears only when a set is
                // longer than the sensor can fire in one request.
                line("Seams", "\(e.bracketSeams) × "
                     + SessionEstimate.formatDuration(DeviceProfile.active.bracketSeam.value)
                     + " — sets longer than the bracket ceiling")
            }
            line("Time", SessionEstimate.formatDuration(calibration.apply(e.typicalSeconds))
                 + " · up to " + SessionEstimate.formatDuration(calibration.apply(e.worstCaseSeconds)))
            if let note = calibration.summary {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            // The plan must not read the same whether its timings were measured
            // here or inherited from another phone.
            if !e.profile.isCharacterised {
                Label("Timings borrowed from a reference \(DeviceProfile.referenceDevice) — "
                      + "measure this device on the Bench to make them yours.",
                      systemImage: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            line("Storage", SessionEstimate.formatBytes(e.typicalBytes)
                 + " · worst case " + SessionEstimate.formatBytes(e.worstCaseBytes))
            if let fits = e.fitsAvailableStorage {
                Text(fits
                     ? "fits available storage at worst case"
                     : "WILL NOT FIT at worst case — the station would abort mid-shoot")
                    .font(.caption2)
                    .foregroundStyle(fits ? .green : .red)
            }
            Text(model.health.summary).font(.caption2)
                .foregroundStyle(model.health.thermalWarning || model.health.batteryWarning
                                 ? .orange : .secondary)
            Text("The pose must be held for the whole of this — swaps and waits included.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption2).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
            Text(v).font(.caption2).monospaced()
            Spacer()
        }
    }

    private func row(icon: String, tint: Color, title: String, detail: String,
                     dim: Bool, bold: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint).frame(width: 16)
                Rectangle().fill(.quaternary).frame(width: 1, height: 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).bold(bold)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(dim ? 0.4 : 1)
        .padding(.vertical, 1)
    }
}
