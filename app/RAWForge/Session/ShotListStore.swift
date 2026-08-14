import Foundation

/// Persists the shot list across launches.
///
/// A shot list is a **plan**, not a station. Losing it to a relaunch mid-scene
/// costs the operator the work of rebuilding it at the pose, which is exactly
/// where attention should be on the pose instead. So it survives.
///
/// This does not weaken "a station either completed or never existed": that
/// rule is about *frames and their record*, and none of those live here. The
/// cursor is deliberately **not** persisted — on relaunch any station in flight
/// is gone, so restoring a half-walked cursor would be restoring a station that
/// never existed.
enum ShotListStore {

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shot-list.json")
    }

    struct Stored: Codable {
        let entries: [ShotListEntry]
        let groupedBySensor: Bool
        let savedAt: Date
    }

    static func save(_ list: ShotList, grouped: Bool) {
        let payload = Stored(entries: list.entries, groupedBySensor: grouped, savedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(payload).write(to: url)
    }

    static func load() -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Stored.self, from: data)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
