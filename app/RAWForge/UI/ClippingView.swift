import SwiftUI

/// The clipping measurement, as bars rather than six-decimal numbers.
///
/// Every frame already carries a full 16-bit histogram per CFA channel over the
/// active area — computed once at capture, when it is nearly free, and expensive
/// to re-derive from a 25 MB file later. Until now it was displayed as columns
/// of numbers, which answers *did I clip* only for someone willing to read them.
///
/// Nothing here crosses #12's line. That rule forbids deriving a statistic from
/// the **viewfinder**, because the preview is tone-mapped and is not the payload.
/// This is the payload.
///
/// ## What it does not do
///
/// It reports and does not advise. The mockup this came from had a "re-shoot one
/// stop down" button, and that button is wrong: the app refuses to judge the
/// scene everywhere else, and a clipped frame is often deliberate — a ladder
/// shot to find where the sensor saturates is *supposed* to blow its top rungs.
/// Dark-frame validation is the one place the app forms a verdict, and #15
/// justified that exception specifically because there is no legitimate reason
/// to record a bright frame as a dark reference. That justification does not
/// transfer to clipping, so neither does the behaviour.
struct ClippingBars: View {
    let stats: ClippingStats
    var compact = false

    var body: some View {
        if let why = stats.unavailableReason {
            Label(why, systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                ForEach(stats.channels, id: \.cfaPosition) { ch in
                    bar(ch)
                }
            }
        }
    }

    private func bar(_ ch: ClippingStats.Channel) -> some View {
        HStack(spacing: 5) {
            if !compact {
                Text(ch.colour).font(.system(size: 9, weight: .bold)).monospaced()
                    .foregroundStyle(tint(ch.colour))
                    .frame(width: 10, alignment: .leading)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint(ch.colour))
                        .frame(width: geo.size.width * min(max(ch.p99Normalised, 0), 1))
                    // The channel keeps its own colour whether or not it
                    // saturated: recolouring a blown bar red would make "the
                    // green channel clipped" unreadable, since the bar that
                    // clipped would then be the colour of the red channel.
                    if ch.isSaturated {
                        HStack(spacing: 0) {
                            Spacer()
                            ZStack {
                                Capsule().fill(.white.opacity(0.92))
                                Text("sat").font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(.black)
                            }
                            .frame(width: 22)
                        }
                    }
                }
            }
            .frame(height: compact ? 5 : 7)
        }
    }

    private func tint(_ colour: String) -> Color {
        switch colour.uppercased() {
        case "R": return .red
        case "B": return .blue
        default:  return .green
        }
    }
}

extension ClippingStats.Channel {
    /// Over half the channel sitting on one value, which only clipping does.
    ///
    /// Taken from the existing note on `modeValue`: this is a *signature*, not
    /// a threshold, which is why the app is willing to state it. It is
    /// deliberately conservative — a frame with a few per cent of blown
    /// highlights will not trip it, and should not, because a few per cent of
    /// blown highlights is a scene rather than a fault.
    var isSaturated: Bool { p50 == p99 }
}

extension ClippingStats {
    var saturatedChannels: [Channel] {
        unavailableReason == nil ? channels.filter(\.isSaturated) : []
    }
    var isSaturated: Bool { !saturatedChannels.isEmpty }
}

/// How a whole capture set came out, at the pose.
///
/// The point of showing this on the capture screen rather than only in the
/// browser is timing: a set that saturated is worth knowing about while the
/// light is still there and the pose is still set, not on a workstation after
/// the walk back.
struct SetClippingSummary: View {
    let frames: [FrameRecord]
    @State private var expanded = false

    private var measured: [FrameRecord] {
        frames.filter { $0.clipping?.unavailableReason == nil && $0.clipping != nil }
    }
    private var saturated: [FrameRecord] {
        measured.filter { $0.clipping?.isSaturated == true }
    }

    var body: some View {
        if measured.isEmpty {
            if !frames.isEmpty {
                Label("No clipping statistics for this set.", systemImage: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: saturated.isEmpty
                              ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                            .foregroundStyle(saturated.isEmpty ? .green : .orange)
                            .font(.caption)
                        Text(headline).font(.caption)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(Array(measured.enumerated()), id: \.offset) { _, f in
                        HStack(alignment: .center, spacing: 8) {
                            Text(f.requested.shutterLabel)
                                .font(.system(size: 9)).monospaced()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            if let c = f.clipping { ClippingBars(stats: c, compact: true) }
                        }
                    }
                    Text("Measured from the Bayer payload over the active area — not from the "
                         + "viewfinder. Saturation is reported, not judged: a ladder shot to find "
                         + "where the sensor blows is meant to blow its top rungs.")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var headline: String {
        if saturated.isEmpty {
            return "\(measured.count) frame(s) · none saturated"
        }
        let names = Set(saturated.flatMap { $0.clipping?.saturatedChannels.map(\.colour) ?? [] })
            .sorted().joined(separator: ", ")
        return "\(saturated.count) of \(measured.count) frame(s) saturated on \(names)"
    }
}

private extension FrameRecord.Exposure {
    var shutterLabel: String {
        shutterSeconds >= 1 ? String(format: "%.1fs", shutterSeconds)
                            : "1/\(Int((1 / max(shutterSeconds, 1e-9)).rounded()))"
    }
}
