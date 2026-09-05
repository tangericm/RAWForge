import Foundation
import Darwin

/// A bookmark only; the complete definition lives in the versioned library.
final class SelectedRecipeStore {
    struct Selection: Codable, Equatable {
        let recipeID: UUID
        let version: Int
    }

    private let url: URL
    init(url: URL = AppStorage.supportFile("selected-recipe.json")) { self.url = url }

    func load() throws -> Selection? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let selected = try RecipeFile.read(Selection.self, from: url)
        guard selected.version > 0 else { throw RecipeStore.Failure.invalidDefinition }
        return selected
    }

    func save(_ recipe: Recipe) throws {
        guard recipe.version > 0 else { throw RecipeStore.Failure.invalidDefinition }
        try RecipeFile.write(Selection(recipeID: recipe.id, version: recipe.version), to: url)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Verify the staged file before publishing it. Immutable versions use a move
/// that refuses an existing destination; mutable bookmarks use atomic rename.
enum RecipeFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    static func write<T: Codable>(_ value: T, to url: URL, immutable: Bool = false,
                                  beforeCommit: (URL) throws -> Void = { _ in }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: temporary, options: .withoutOverwriting)
        _ = try read(T.self, from: temporary)
        try beforeCommit(url)
        if immutable {
            try fm.moveItem(at: temporary, to: url)
        } else if rename(temporary.path, url.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
