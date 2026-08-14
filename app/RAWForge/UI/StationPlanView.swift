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

    private var estimate: SessionEstimate {
        SessionEstimate.forShotList(model.shotList.entries, mode: model.mode,
                                    minimumGap: model.minimumGap)
    }

    var body: some View {
        let e = estimate
        return Section("Plan") {
            if model.shotList.entries.isEmpty {
                Text("nothing planned").font(.caption).foregroundStyle(.secondary)
            } else {
                timeline
                Divider()
                budget(e)
            }
        }
    }

    /// One row per set, dimmed once the cursor has passed it. The swap rows
    /// exist because a swap costs longer than an entire 8-frame bracket, and a
    /// plan that hides its most expensive step is misleading.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.shotList.entries.enumerated()), id: \.element.id) { i, entry in
                let isPast = i < model.shotList.cursor
                let isNow = i == model.shotList.cursor
                let newSensor = i == 0 || model.shotList.entries[i - 1].sensor != entry.sensor

                if newSensor {
                    row(icon: "arrow.triangle.swap", tint: .purple,
                        title: "swap to \(entry.sensor.rawValue)",
                        detail: SessionEstimate.formatDuration(SessionEstimate.sensorSwap)
                            + " · pose held, nothing shot",
                        dim: isPast)
                    row(icon: "hand.raised", tint: .blue, title: "settle",
                        detail: SessionEstimate.formatDuration(SessionEstimate.stillnessTimeout)
                            + " · measured tap-transient decay", dim: isPast)
                }
                row(icon: isPast ? "checkmark.circle.fill"
                        : isNow ? "arrowtriangle.right.fill" : "circle",
                    tint: isPast ? .green : isNow ? .accentColor : .secondary,
                    title: entry.captureSet.name + " v\(entry.captureSet.version)",
                    detail: "\(entry.frameCount) frames · "
                        + SessionEstimate.formatDuration(setDuration(entry)),
                    dim: isPast, bold: isNow)
            }
        }
    }

    private func setDuration(_ entry: ShotListEntry) -> TimeInterval {
        SessionEstimate.forShotList([entry], mode: model.mode,
                                    minimumGap: model.minimumGap,
                                    includeStillness: false).typicalSeconds
    }

    private func budget(_ e: SessionEstimate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            line("Frames", "\(e.frameCount) across \(e.sensorSwaps) sensor(s)")
            line("Exposure", SessionEstimate.formatDuration(e.exposureSeconds))
            line("Overhead", SessionEstimate.formatDuration(e.overheadSeconds)
                 + " (swaps, per-frame, gaps)")
            line("Time", SessionEstimate.formatDuration(e.typicalSeconds)
                 + " · up to " + SessionEstimate.formatDuration(e.worstCaseSeconds) + " with waits")
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
