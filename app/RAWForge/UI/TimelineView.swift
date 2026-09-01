import SwiftUI

/// The station drawn against a clock.
///
/// A list of sets answers *what will be shot*. It cannot answer the question
/// that actually costs a pose — **how much of this is not shooting** — because
/// the expensive steps are the ones nobody added on purpose: the sensor swap,
/// the settle after it, the seam where a set outgrows one hardware request.
///
/// ## The scale problem, and what was actually done
///
/// The first attempt drew each block's *height* proportional to its duration.
/// That failed, and it failed for a reason worth recording: a block has to be
/// tall enough to hold a title, a ladder and a caption — about 130 points — so
/// every block below roughly three seconds came out the same size. A 264 ms set
/// and a 3.8 s set were drawn identically while the view claimed to be to
/// scale. The axis was fiction and the disclaimer underneath it was worse than
/// nothing, because it asserted a precision that was not there.
///
/// A non-linear axis would have been worse still: a plan whose axis lies cannot
/// be read at a glance, which was the whole reason to draw it.
///
/// So duration is encoded as a **bar within each row**, exact against the
/// longest step, and rows are uniform. Nothing is clipped, nothing is claimed
/// that is not true, and a 450:1 ratio between the shortest and longest step is
/// still legible — the short bar is simply short.
struct StationTimeline: View {
    let entries: [ShotListEntry]
    let cursor: Int
    let estimate: SessionEstimate
    let minimumGap: TimeInterval
    let bracketCeiling: Int?

    private var steps: [Step] { Self.steps(entries: entries, minimumGap: minimumGap,
                                           bracketCeiling: bracketCeiling) }

    var body: some View {
        let all = steps
        let longest = all.map(\.seconds).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(all.enumerated()), id: \.offset) { _, step in
                row(step, fraction: Self.barFraction(step.seconds, longest: longest),
                    dim: step.setIndex.map { $0 < cursor } ?? false,
                    now: step.setIndex.map { $0 == cursor } ?? false)
            }
            Text("Bars are exact against the longest step (\(SessionEstimate.formatDuration(longest))).")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
    }

    /// Linear and exact. There is no floor, because a bar can be one point wide
    /// and still be honest — which is precisely what a block's *height* could
    /// not do once it had to hold text.
    static func barFraction(_ seconds: TimeInterval, longest: TimeInterval) -> Double {
        guard longest > 0, seconds > 0 else { return 0 }
        return min(1, seconds / longest)
    }

    private func row(_ step: Step, fraction: Double, dim: Bool, now: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(step.kind.tint).frame(width: 7, height: 7)
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: step.kind.icon).font(.system(size: 10))
                    Text(step.title).font(.caption).bold(now)
                    if let s = step.sensor {
                        Text(s).font(.system(size: 9)).monospaced()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Text(SessionEstimate.formatDuration(step.seconds))
                        .font(.system(size: 9)).monospaced().foregroundStyle(.secondary)
                }
                .foregroundStyle(step.kind == .set ? Color.primary : step.kind.tint)

                // Duration, exactly. The eye compares these across rows, which
                // is the comparison the whole view exists to make.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 4)
                        Capsule().fill(step.kind.tint)
                            .frame(width: max(1, geo.size.width * fraction), height: 4)
                    }
                }
                .frame(height: 4)

                if let rungs = step.rungs, rungs.count > 1 {
                    LadderBars(rungs: rungs, seamAfter: step.seamAfter)
                }
                Text(step.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(step.kind == .set ? 8 : 0)
            .background(step.kind == .set
                        ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                        : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .opacity(dim ? 0.4 : 1)
        .padding(.vertical, 3)
    }

    // MARK: - Steps

    enum Kind {
        case swap, settle, set

        var tint: Color {
            switch self {
            case .swap:   return .purple
            case .settle: return .indigo
            case .set:    return .accentColor
            }
        }
        var icon: String {
            switch self {
            case .swap:   return "arrow.triangle.swap"
            case .settle: return "hand.raised.fill"
            case .set:    return "camera.aperture"
            }
        }
    }

    struct Step {
        let kind: Kind
        let title: String
        let detail: String
        let seconds: TimeInterval
        var sensor: String?
        /// Relative exposure of each rung, 0-1, for the ladder sparkline.
        var rungs: [Double]?
        var seamAfter: Int?
        /// Index into the shot list, for dimming what is already shot.
        var setIndex: Int?
    }

    /// Derived rather than stored: the swaps and settles are consequences of the
    /// shot list, and duplicating them would let the drawing disagree with the
    /// estimate the plan quotes.
    static func steps(entries: [ShotListEntry], minimumGap: TimeInterval,
                      bracketCeiling: Int?) -> [Step] {
        var out: [Step] = []
        var previousSensor: SensorCapability.Sensor?
        let profile = DeviceProfile.active

        for (i, entry) in entries.enumerated() {
            // Every set has a setup step, but only a changed sensor rebuilds
            // the graph. A consecutive set reuses the live graph and carries
            // its own measured cost.
            let first = previousSensor == nil
            let changed = !first && entry.sensor != previousSensor
            let title: String
            let setupDetail: String
            let seconds: TimeInterval
            if first {
                title = "Prepare \(entry.sensor.rawValue)"
                setupDetail = "bring this sensor's capture graph online"
                seconds = profile.sensorSwap.value
            } else if changed {
                title = "Swap to \(entry.sensor.rawValue)"
                setupDetail = "the pose is held and nothing is shot"
                seconds = profile.sensorSwap.value
            } else {
                title = "Reuse \(entry.sensor.rawValue)"
                setupDetail = "capture graph is already live"
                seconds = profile.sameSensorSetupCost.value
            }
            out.append(Step(
                kind: .swap,
                title: title,
                detail: setupDetail,
                seconds: seconds))
            out.append(Step(kind: .settle, title: "Settle",
                            detail: "measured decay of the tap transient",
                            seconds: profile.stillnessTimeout.value))
            previousSensor = entry.sensor

            let specs = entry.captureSet.rendered(for: entry.sensor)
            let one = SessionEstimate.forShotList([entry], minimumGap: minimumGap,
                                                  includeStillness: false,
                                                  bracketCeiling: bracketCeiling)
            let requests = entry.captureSet.firing == .hardwareBracket
                ? SessionEstimate.requestCount(frames: specs.count, ceiling: bracketCeiling ?? 0)
                : 0
            var detail = "\(specs.count) frames · \(entry.captureSet.firing.label.lowercased())"
            if requests > 1 { detail += " · \(requests) requests" }

            let longest = specs.map(\.shutterSeconds).max() ?? 1
            out.append(Step(
                kind: .set,
                title: "\(entry.captureSet.name) v\(entry.captureSet.version)",
                detail: detail,
                seconds: one.typicalSeconds - one.breakdown.setup,
                sensor: entry.sensor.rawValue,
                rungs: specs.map { longest > 0 ? $0.shutterSeconds / longest : 1 },
                seamAfter: requests > 1 ? bracketCeiling : nil,
                setIndex: i))
        }
        return out
    }
}

/// The ladder's own shape, drawn from its exposures.
///
/// A sweep centred a stop off is visible here before it is shot, which is the
/// one thing a list of numbers cannot deliver at a glance.
struct LadderBars: View {
    let rungs: [Double]
    var seamAfter: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(rungs.prefix(48).enumerated()), id: \.offset) { i, r in
                if let seam = seamAfter, i == seam, i > 0 {
                    Rectangle().fill(.orange).frame(width: 1.5, height: 22)
                        .padding(.horizontal, 1)
                }
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: rungs.count > 24 ? 3 : 7,
                           height: 4 + CGFloat(min(max(r, 0), 1)) * 18)
            }
            if rungs.count > 48 {
                Text("+\(rungs.count - 48)").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Where a station's time goes, as one bar.
///
/// The headline the plan should deliver without being read: on a three-sensor
/// station most of the clock is swaps and settles, not exposure.
struct TimeBudgetBar: View {
    let breakdown: SessionEstimate.Breakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(breakdown.parts.enumerated()), id: \.offset) { _, part in
                        Rectangle()
                            .fill(tint(part.name))
                            .frame(width: max(1, geo.size.width
                                              * CGFloat(part.seconds / max(breakdown.total, 0.001))))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            HStack(spacing: 8) {
                ForEach(Array(breakdown.parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 3) {
                        Circle().fill(tint(part.name)).frame(width: 5, height: 5)
                        Text(part.name).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func tint(_ name: String) -> Color {
        switch name {
        case "Exposure":      return .accentColor
        case "Sensor setup":  return .purple
        case "Settling":      return .indigo
        case "Bracket seams": return .orange
        case "Gaps":          return .teal
        default:              return .gray
        }
    }
}
