import Foundation

struct RunMetadata: Codable, Equatable {
    var name: String
    var note: String?
}

/// Presentation edits are sidecars; capture-time headers remain immutable.
final class RunMetadataStore {
    private let root: URL
    init(root: URL = SessionStore.sessionsRoot) { self.root = root }

    func load(sessionID: String) throws -> RunMetadata? {
        let url = try metadataURL(sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try RecipeFile.read(RunMetadata.self, from: url)
    }

    func save(_ metadata: RunMetadata, sessionID: String) throws {
        let url = try metadataURL(sessionID)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
            .appendingPathComponent("session.json").path) else { throw ActiveRunStore.Failure.invalidRun }
        try RecipeFile.write(metadata, to: url)
    }

    private func metadataURL(_ id: String) throws -> URL {
        try ActiveRunStore.validateID(id)
        let directory = root.appendingPathComponent(id)
        for path in [root, directory] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
                throw ActiveRunStore.Failure.invalidRun
            }
        }
        return directory.appendingPathComponent("run-metadata.json")
    }
}
