import Foundation

/// Remembers a group, never an in-flight Take or a camera cursor.
final class ActiveRunStore {
    struct Pointer: Codable { let schemaVersion: Int; let sessionID: String }
    struct RecoveredRun: Equatable { let sessionID: String; let nextTakeIndex: Int }
    struct Recovery { let run: RecoveredRun?; let warning: String? }

    enum Failure: LocalizedError {
        case invalidRun, busy
        var errorDescription: String? {
            switch self {
            case .invalidRun: return "The previous run could not be resumed safely. Its saved captures have been preserved."
            case .busy: return "Finish the current run before opening another."
            }
        }
    }

    private let url: URL
    init(url: URL = AppStorage.supportFile("active-run.json")) { self.url = url }

    static func validateID(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else { throw Failure.invalidRun }
    }

    func activate(sessionID: String) throws {
        try Self.validateID(sessionID)
        try RecipeFile.write(Pointer(schemaVersion: 1, sessionID: sessionID), to: url)
    }

    func pointer() throws -> Pointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pointer = try RecipeFile.read(Pointer.self, from: url)
        guard pointer.schemaVersion == 1 else { throw Failure.invalidRun }
        try Self.validateID(pointer.sessionID)
        return pointer
    }

    func finish() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func recover(loadSession: (String) -> SessionRecord?,
                 loadStations: (String) -> (stations: [StationRecord], unreadable: [String])) throws -> Recovery {
        do {
            guard let pointer = try pointer() else { return Recovery(run: nil, warning: nil) }
            let validated = try Self.validate(sessionID: pointer.sessionID,
                loadSession: loadSession, loadStations: loadStations)
            return Recovery(run: validated.run, warning: nil)
        } catch {
            // Only remove the bookmark, never the Run or any of its records.
            try finish()
            return Recovery(run: nil, warning: Failure.invalidRun.localizedDescription)
        }
    }

    static func validate(sessionID: String, loadSession: (String) -> SessionRecord?,
                         loadStations: (String) -> (stations: [StationRecord], unreadable: [String])) throws
        -> (run: RecoveredRun, session: SessionRecord) {
        try validateID(sessionID)
        guard let session = loadSession(sessionID), session.sessionId == sessionID,
              session.sessionType == "scene" else { throw Failure.invalidRun }
        let records = loadStations(sessionID)
        let indices = records.stations.map(\.stationIndex)
        guard records.unreadable.isEmpty, records.stations.allSatisfy({ $0.sessionId == sessionID }),
              indices.allSatisfy({ $0 > 0 && $0 < Int.max }), Set(indices).count == indices.count else {
            throw Failure.invalidRun
        }
        return (RecoveredRun(sessionID: sessionID, nextTakeIndex: (indices.max() ?? 0) + 1), session)
    }
}
