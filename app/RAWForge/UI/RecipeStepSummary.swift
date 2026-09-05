import Foundation

/// Display the values this camera will receive, including its exposure offset.
/// Invalid drafts remain visible for correction instead of crashing formatting.
struct RecipeStepSummary {
    let shutterRange: ClosedRange<Double>?
    let isoRange: ClosedRange<Float>?
    let normalizedExposures: [Double]
    let intervalSeconds: TimeInterval?

    init(step: RecipeStep) {
        let specs = step.captureSet.rendered(for: step.sensor)
        let valid = !specs.isEmpty && specs.allSatisfy {
            $0.shutterSeconds.isFinite && $0.shutterSeconds > 0 && $0.iso.isFinite && $0.iso > 0
        }
        if valid, let shortest = specs.map(\.shutterSeconds).min(),
           let longest = specs.map(\.shutterSeconds).max(),
           let lowISO = specs.map(\.iso).min(), let highISO = specs.map(\.iso).max() {
            shutterRange = shortest...longest
            isoRange = lowISO...highISO
            normalizedExposures = specs.map { $0.shutterSeconds / longest }
        } else {
            shutterRange = nil
            isoRange = nil
            normalizedExposures = []
        }
        intervalSeconds = step.captureSet.firing == .sequential ? step.sequentialGapSeconds : nil
    }

    var exposureText: String {
        guard let shutterRange, let isoRange else { return "Review invalid frame values" }
        func range(_ low: Double, _ high: Double) -> String {
            low == high ? String(format: "%.4g", low) : String(format: "%.4g–%.4g", low, high)
        }
        return "\(range(shutterRange.lowerBound, shutterRange.upperBound)) s · ISO \(range(Double(isoRange.lowerBound), Double(isoRange.upperBound)))"
    }
}
