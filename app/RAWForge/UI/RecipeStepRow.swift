import SwiftUI

/// Ordered blocks are still native list rows, not a second navigation system.
struct RecipeStepRow: View {
    let step: RecipeStep
    let position: Int

    var body: some View {
        let summary = RecipeStepSummary(step: step)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(position)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Text(step.captureSet.name).font(.headline)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { camera; firing; frames }
                VStack(alignment: .leading, spacing: 6) { camera; firing; frames }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Text(summary.exposureText).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            if summary.normalizedExposures.count > 1 {
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(summary.normalizedExposures.prefix(24).enumerated()), id: \.offset) { _, fraction in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.secondary)
                                .frame(height: geometry.size.height * fraction)
                        }
                    }.frame(maxHeight: .infinity, alignment: .bottom)
                }.frame(height: 28).accessibilityHidden(true)
                if summary.normalizedExposures.count > 24 {
                    Text("Shutter pattern · first 24 of \(summary.normalizedExposures.count) frames")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let interval = summary.intervalSeconds {
                Text("Minimum interval \(interval.formatted()) s")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if step.dwellSeconds > 0 {
                Text("Wait \(step.dwellSeconds.formatted()) s before this Step")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var camera: some View { Label(step.sensor.rawValue, systemImage: "camera") }
    private var firing: some View { Text(step.captureSet.firing.label).fontWeight(.medium) }
    private var frames: some View {
        Text("\(step.captureSet.specs.count) \(step.captureSet.specs.count == 1 ? "frame" : "frames")")
            .monospacedDigit()
    }
}
