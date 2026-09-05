import Foundation

struct RecipeValidation: Equatable {
    enum Blocker: Equatable {
        case emptyRecipe
        case invalidStep(RecipeStep.ValidationError)
        case missingSensor
        case unusableSensor(reason: String)
        case invalidExposure(rungIndex: Int)
        case noSupportedRungs
    }

    struct StepResult: Equatable {
        let stepID: UUID
        let stepIndex: Int
        let sensor: SensorCapability.Sensor
        /// Actual sensor-adjusted values, matching the existing controller's rails.
        let kept: [CaptureSpec]
        let dropped: [DroppedRung]
        /// Original positions, parallel to `dropped`; repeated equal specs remain
        /// separate occurrences, and adaptation can retain canonical EV offsets.
        let droppedRungIndices: [Int]
        let blockers: [Blocker]
    }

    let steps: [StepResult]
    let recipeBlockers: [Blocker]
    var blockers: [Blocker] { recipeBlockers + steps.flatMap(\.blockers) }
    var canCapture: Bool { blockers.isEmpty }
    var hasWarnings: Bool { steps.contains { !$0.dropped.isEmpty } }
}

struct RecipeAdaptation: Equatable {
    struct Change: Equatable {
        let stepID: UUID
        let stepIndex: Int
        let sensor: SensorCapability.Sensor
        let rungIndex: Int
        let authoredSpec: CaptureSpec
        /// Includes the rendered exposure and existing rail validator's reason.
        let dropped: DroppedRung
    }

    /// Nil on any blocker: never substitute sensors or erase an entire Step.
    let recipe: Recipe?
    let validation: RecipeValidation
    /// Every removed occurrence in Step/rung order. Identity, version, name and
    /// timestamps of the new copy are available on `recipe`, not rung changes.
    let changes: [Change]
}

enum RecipeValidator {
    static func validate(_ recipe: Recipe, against report: CapabilityReport) -> RecipeValidation {
        let steps = recipe.steps.enumerated().map { index, step in
            validate(step, index: index, against: report)
        }
        return RecipeValidation(steps: steps, recipeBlockers: recipe.steps.isEmpty ? [.emptyRecipe] : [])
    }

    static func adaptedCopy(of recipe: Recipe, against report: CapabilityReport,
                            now: Date) -> RecipeAdaptation {
        let validation = validate(recipe, against: report)
        guard validation.canCapture else {
            return RecipeAdaptation(recipe: nil, validation: validation, changes: [])
        }

        var steps = recipe.steps
        var changes: [RecipeAdaptation.Change] = []
        for result in validation.steps where !result.dropped.isEmpty {
            let set = steps[result.stepIndex].captureSet
            let removed = Set(result.droppedRungIndices)
            for (rungIndex, dropped) in zip(result.droppedRungIndices, result.dropped) {
                changes.append(.init(stepID: result.stepID, stepIndex: result.stepIndex,
                                     sensor: result.sensor, rungIndex: rungIndex,
                                     authoredSpec: set.specs[rungIndex], dropped: dropped))
            }
            // Filter canonical rungs, not rendered values: retaining the offset
            // must not apply it twice. Generator remains authoring provenance;
            // specs, as in CaptureSet, are the authoritative frame definition.
            steps[result.stepIndex].captureSet = CaptureSet(
                name: set.name, version: set.version,
                specs: set.specs.enumerated().filter { !removed.contains($0.offset) }.map(\.element),
                generator: set.generator, perSensorEVOffsetStops: set.perSensorEVOffsetStops,
                executionMode: set.executionMode)
        }
        let copy = Recipe(id: UUID(), name: "\(recipe.name) (\(report.device.modelIdentifier))", version: 1,
                          createdAt: now, modifiedAt: now, steps: steps,
                          note: recipe.note, schemaVersion: recipe.schemaVersion)
        return RecipeAdaptation(recipe: copy, validation: validation, changes: changes)
    }

    private static func validate(_ step: RecipeStep, index: Int,
                                 against report: CapabilityReport) -> RecipeValidation.StepResult {
        var blockers = step.validationErrors.map { RecipeValidation.Blocker.invalidStep($0) }
        var kept: [CaptureSpec] = []
        var dropped: [DroppedRung] = []
        var droppedIndices: [Int] = []

        if let sensor = report.sensors.first(where: { $0.sensor == step.sensor }) {
            if !sensor.isUsable {
                blockers.append(.unusableSensor(reason: sensor.exclusionReason ?? "sensor cannot produce Bayer RAW"))
            } else {
                let rendered = step.captureSet.rendered(for: step.sensor)
                for (rungIndex, spec) in rendered.enumerated() {
                    let authored = step.captureSet.specs[rungIndex]
                    // NaN compares neither below nor above a rail. Reject invalid
                    // numbers before the old rail validator or any label formatting.
                    guard isValidExposure(authored), isValidExposure(spec) else {
                        blockers.append(.invalidExposure(rungIndex: rungIndex))
                        continue
                    }
                    let rung = CaptureSet(name: step.captureSet.name, version: step.captureSet.version,
                                          specs: [spec], generator: .manual, perSensorEVOffsetStops: [:],
                                          executionMode: step.captureSet.executionMode)
                    let checked = rung.validated(against: sensor)
                    kept.append(contentsOf: checked.kept)
                    if let rejected = checked.dropped.first {
                        dropped.append(rejected)
                        droppedIndices.append(rungIndex)
                    }
                }
                if kept.isEmpty { blockers.append(.noSupportedRungs) }
            }
        } else {
            blockers.append(.missingSensor)
        }
        return RecipeValidation.StepResult(stepID: step.id, stepIndex: index, sensor: step.sensor,
                                           kept: kept, dropped: dropped, droppedRungIndices: droppedIndices,
                                           blockers: blockers)
    }

    private static func isValidExposure(_ spec: CaptureSpec) -> Bool {
        spec.shutterSeconds.isFinite && spec.shutterSeconds > 0 && spec.iso.isFinite && spec.iso > 0
    }
}
