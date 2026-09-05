import Foundation

/// A reusable definition, not an executor. StationController still owns capture.
/// Focus belongs to the current pose and is deliberately absent from this schema.
struct Recipe: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let version: Int
    let createdAt: Date
    var modifiedAt: Date
    var steps: [RecipeStep]
    var note: String?
    let schemaVersion: Int

    /// Preserves authored order and firing; callers validate before execution.
    func renderedEntries() -> [ShotListEntry] {
        steps.enumerated().map { index, step in
            ShotListEntry(index: index, sensor: step.sensor, captureSet: step.captureSet,
                          dwellSeconds: step.dwellSeconds,
                          minimumGapSeconds: step.sequentialGapSeconds)
        }
    }
}

struct RecipeStep: Codable, Equatable, Identifiable {
    let id: UUID
    var sensor: SensorCapability.Sensor
    var captureSet: CaptureSet
    var dwellSeconds: TimeInterval
    var sequentialGapSeconds: TimeInterval?

    enum ValidationError: Error, Equatable {
        case invalidDwell
        case invalidSequentialGap
        case emptyCaptureSet
        case burstHasGap
    }

    // The synthesized memberwise initializer stays internal for reconstruction.
    // New authored steps use this factory; decoded/mutated drafts are revalidated
    // by RecipeValidator rather than trapping or silently repairing their values.
    static func validated(id: UUID = UUID(), sensor: SensorCapability.Sensor,
                          captureSet: CaptureSet, dwellSeconds: TimeInterval = 0,
                          sequentialGapSeconds: TimeInterval? = nil) throws -> RecipeStep {
        var explicitSet = captureSet
        explicitSet.executionMode = captureSet.firing
        let step = RecipeStep(id: id, sensor: sensor, captureSet: explicitSet,
                              dwellSeconds: dwellSeconds, sequentialGapSeconds: sequentialGapSeconds)
        if let error = step.validationErrors.first { throw error }
        return step
    }

    var validationErrors: [ValidationError] {
        var errors: [ValidationError] = []
        if !dwellSeconds.isFinite || dwellSeconds < 0 { errors.append(.invalidDwell) }
        if let gap = sequentialGapSeconds, !gap.isFinite || gap < 0 {
            errors.append(.invalidSequentialGap)
        }
        if captureSet.specs.isEmpty { errors.append(.emptyCaptureSet) }
        if captureSet.firing == .hardwareBracket && sequentialGapSeconds != nil {
            errors.append(.burstHasGap)
        }
        return errors
    }
}

/// A value copy embeds the entire definition so later draft edits cannot rewrite it.
struct RecipeSnapshot: Codable, Equatable {
    let recipeID: UUID
    let name: String
    let version: Int
    let capturedDefinition: Recipe

    init(_ recipe: Recipe) {
        recipeID = recipe.id
        name = recipe.name
        version = recipe.version
        capturedDefinition = recipe
    }
}
