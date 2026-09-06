import Foundation

/// Immutable, user-owned definitions. File failures propagate to the workflow
/// so a failed save cannot look like a successful edit. Call from the UI actor.
final class RecipeStore {
    enum Failure: LocalizedError {
        case invalidDefinition, unsupportedSchema(Int), identityMismatch, alreadyExists, missingRecipe
        case selectedRecipe, noCompatibleSensor, unsafePath, migrationConflict

        var errorDescription: String? {
            switch self {
            case .invalidDefinition: return "The recipe contains an invalid name, step, or timing value."
            case .unsupportedSchema(let version): return "This recipe uses unsupported format \(version). Its file has been preserved."
            case .identityMismatch: return "The recipe identity does not match its version file."
            case .alreadyExists: return "This recipe already exists. Save an edit as a new version."
            case .missingRecipe: return "The recipe could not be found."
            case .selectedRecipe: return "Select another recipe before deleting this one."
            case .noCompatibleSensor: return "No available RAW sensor has usable exposure limits."
            case .unsafePath: return "The recipe folder is a symbolic link. No files were changed."
            case .migrationConflict: return "The published recipe differs from the pending import. The recipe, import journal, legacy draft, and selection have been preserved."
            }
        }
    }

    private struct Index: Codable {
        var schemaVersion = 1
        var archived: Set<UUID> = []
        var starters: Set<UUID> = []
    }

    private struct Migration: Codable {
        var schemaVersion = 1
        // Freeze the source before the first version write. Even a crash after
        // legacy deletion can finish without inventing another imported ID.
        let recipe: Recipe
        var completed = false
    }

    private let root: URL
    private let selection: SelectedRecipeStore
    private let migrationURL: URL
    private let beforeCommit: (URL) throws -> Void
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init(root: URL = AppStorage.documentsDirectory.appendingPathComponent("recipes"),
         selection: SelectedRecipeStore = SelectedRecipeStore(),
         migrationURL: URL = AppStorage.supportFile("recipe-migration-v1.json"),
         beforeCommit: @escaping (URL) throws -> Void = { _ in }) {
        self.root = root
        self.selection = selection
        self.migrationURL = migrationURL
        self.beforeCommit = beforeCommit
    }

    func all(includeArchived: Bool = false) throws -> [Recipe] {
        try rejectSymlink(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let index = try readIndex()
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try directories.compactMap { directory -> Recipe? in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  includeArchived || !index.archived.contains(id) else { return nil }
            guard let version = try versions(id).max() else { return nil }
            return try load(id: id, version: version)
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func load(id: UUID, version: Int) throws -> Recipe? {
        guard version > 0 else { throw Failure.invalidDefinition }
        let url = try versionURL(id, version)
        try rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let recipe = try RecipeFile.read(Recipe.self, from: url)
        try check(recipe)
        guard recipe.id == id, recipe.version == version else { throw Failure.identityMismatch }
        return recipe
    }

    @discardableResult
    func create(_ draft: Recipe, now: Date = Date()) throws -> Recipe {
        guard try versions(draft.id).isEmpty else { throw Failure.alreadyExists }
        let recipe = Recipe(id: draft.id, name: draft.name, version: 1, createdAt: now, modifiedAt: now,
                            steps: draft.steps, note: draft.note, schemaVersion: draft.schemaVersion)
        return try publish(recipe)
    }

    @discardableResult
    func saveVersion(_ draft: Recipe, now: Date = Date()) throws -> Recipe {
        guard let latestVersion = try versions(draft.id).max(),
              let latest = try load(id: draft.id, version: latestVersion) else { throw Failure.missingRecipe }
        guard latestVersion < Int.max else { throw Failure.invalidDefinition }
        return try publish(Recipe(id: draft.id, name: draft.name, version: latestVersion + 1,
            createdAt: latest.createdAt, modifiedAt: now, steps: draft.steps, note: draft.note,
            schemaVersion: draft.schemaVersion))
    }

    func duplicate(_ recipe: Recipe, now: Date = Date()) throws -> Recipe {
        try create(Recipe(id: UUID(), name: recipe.name + " Copy", version: 1,
            createdAt: now, modifiedAt: now, steps: recipe.steps, note: recipe.note,
            schemaVersion: recipe.schemaVersion), now: now)
    }

    func archive(id: UUID, archived: Bool) throws {
        guard !(try versions(id)).isEmpty else { throw Failure.missingRecipe }
        var index = try readIndex()
        if archived { index.archived.insert(id) } else { index.archived.remove(id) }
        try RecipeFile.write(index, to: indexURL, beforeCommit: beforeCommit)
    }

    func delete(id: UUID) throws {
        // A corrupt bookmark is not permission to delete its possibly selected
        // definition. Repair the selection explicitly before retrying.
        guard try selection.load()?.recipeID != id else { throw Failure.selectedRecipe }
        let directory = try recipeDirectory(id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        // Stale index IDs are harmless; no version file is modified for an index.
    }

    func ensureStarterSelected(report: CapabilityReport, now: Date = Date()) throws -> Recipe {
        if let bookmark = try? selection.load(),
           let selected = try load(id: bookmark.recipeID, version: bookmark.version) {
            // Keep the user's explicit choice even when this phone cannot run
            // it. Validation explains that; never substitute a different recipe.
            return selected
        }
        let index = try readIndex()
        if let starter = try all().first(where: {
            index.starters.contains($0.id) && RecipeValidator.validate($0, against: report).canCapture
                && !RecipeValidator.validate($0, against: report).hasWarnings
        }) {
            try selection.save(starter)
            return starter
        }
        guard let sensor = report.usableSensors.first(where: {
            guard let minISO = $0.minISO, let maxISO = $0.maxISO,
                  let minS = $0.minExposureSeconds, let maxS = $0.maxExposureSeconds else { return false }
            return minISO.isFinite && maxISO.isFinite && minISO > 0 && maxISO >= minISO
                && minS.isFinite && maxS.isFinite && minS > 0 && maxS >= minS
        }), let minISO = sensor.minISO, let maxISO = sensor.maxISO,
            let minS = sensor.minExposureSeconds, let maxS = sensor.maxExposureSeconds else {
            throw Failure.noCompatibleSensor
        }
        let spec = CaptureSpec(shutterSeconds: min(max(1.0 / 125, minS), maxS),
                               iso: min(max(100, minISO), maxISO))
        var set = CaptureSet.repeated(spec, count: 1, name: "Single Frame", version: 1)
        set.executionMode = .hardwareBracket
        let starter = try create(Recipe(id: UUID(), name: "Single Frame", version: 1,
            createdAt: now, modifiedAt: now,
            steps: [try .validated(sensor: sensor.sensor, captureSet: set)], note: nil, schemaVersion: 1), now: now)
        var updatedIndex = index
        updatedIndex.starters.insert(starter.id)
        try RecipeFile.write(updatedIndex, to: indexURL, beforeCommit: beforeCommit)
        try selection.save(starter)
        return starter
    }

    /// The caller supplies legacy deletion so its failure is observable. A
    /// durable intent precedes the version; selection precedes source deletion.
    func migrateShotListIfNeeded(_ stored: ShotListStore.Stored?, now: Date = Date(),
                                dwellSeconds: TimeInterval? = nil,
                                sequentialGapSeconds: TimeInterval? = nil,
                                clearLegacy: () throws -> Void) throws -> Recipe? {
        var migration: Migration
        if FileManager.default.fileExists(atPath: migrationURL.path) {
            migration = try RecipeFile.read(Migration.self, from: migrationURL)
            guard migration.schemaVersion == 1 else { throw Failure.unsupportedSchema(migration.schemaVersion) }
            guard !migration.completed else { return nil }
        } else {
            guard try all(includeArchived: true).isEmpty, let stored, !stored.entries.isEmpty else { return nil }
            let steps = try stored.entries.map { entry in
                let step = RecipeStep(id: UUID(), sensor: entry.sensor, captureSet: entry.captureSet,
                    dwellSeconds: dwellSeconds ?? entry.dwellSeconds,
                    sequentialGapSeconds: entry.captureSet.firing == .sequential
                        ? sequentialGapSeconds ?? entry.minimumGapSeconds : nil)
                guard step.validationErrors.isEmpty else { throw Failure.invalidDefinition }
                return step
            }
            migration = Migration(recipe: Recipe(id: UUID(), name: "Imported capture", version: 1,
                createdAt: now, modifiedAt: now, steps: steps, note: nil, schemaVersion: 1))
            try RecipeFile.write(migration, to: migrationURL, beforeCommit: beforeCommit)
            // Compare in the durable date precision, including on the first attempt.
            migration = try RecipeFile.read(Migration.self, from: migrationURL)
        }
        let recipe: Recipe
        if let existing = try load(id: migration.recipe.id, version: 1) {
            recipe = existing
        } else {
            recipe = try create(migration.recipe, now: migration.recipe.createdAt)
        }
        // Matching identity alone cannot authorize deletion of the frozen source.
        guard recipe == migration.recipe else { throw Failure.migrationConflict }
        try selection.save(recipe)
        try clearLegacy()
        migration.completed = true
        try RecipeFile.write(migration, to: migrationURL, beforeCommit: beforeCommit)
        return recipe
    }

    private func publish(_ recipe: Recipe) throws -> Recipe {
        try check(recipe)
        let url = try versionURL(recipe.id, recipe.version)
        try RecipeFile.write(recipe, to: url, immutable: true, beforeCommit: beforeCommit)
        // Return the serialized dates, not higher-precision in-memory values.
        guard let persisted = try load(id: recipe.id, version: recipe.version) else { throw Failure.missingRecipe }
        return persisted
    }

    private func check(_ recipe: Recipe) throws {
        guard recipe.schemaVersion == 1 else { throw Failure.unsupportedSchema(recipe.schemaVersion) }
        guard recipe.version > 0, !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !recipe.steps.isEmpty, recipe.steps.allSatisfy({ $0.validationErrors.isEmpty }),
              Set(recipe.steps.map(\.id)).count == recipe.steps.count else { throw Failure.invalidDefinition }
    }

    private func readIndex() throws -> Index {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return Index() }
        let index = try RecipeFile.read(Index.self, from: indexURL)
        guard index.schemaVersion == 1 else { throw Failure.unsupportedSchema(index.schemaVersion) }
        return index
    }

    private func versions(_ id: UUID) throws -> [Int] {
        let directory = try recipeDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap { name in
            guard name.hasPrefix("v"), name.hasSuffix(".json"),
                  let number = Int(name.dropFirst().dropLast(5)), number > 0 else { return nil }
            return number
        }
    }

    private func recipeDirectory(_ id: UUID) throws -> URL {
        try rejectSymlink(root)
        let directory = root.appendingPathComponent(id.uuidString)
        try rejectSymlink(directory)
        return directory
    }

    private func versionURL(_ id: UUID, _ version: Int) throws -> URL {
        try recipeDirectory(id).appendingPathComponent(String(format: "v%04ld.json", version))
    }

    private func rejectSymlink(_ url: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw Failure.unsafePath
        }
    }
}
