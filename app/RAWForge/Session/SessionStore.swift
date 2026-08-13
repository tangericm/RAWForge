import Foundation

/// One directory per session, frames flat inside it (#9).
///
/// The session directory is the unit that gets moved and the unit that gets
/// deleted once transferred. Nesting session/station/bracket/frame was
/// rejected: transfer paths flatten, AirDrop delivers loose files, and the
/// structure is already in the log more reliably.
enum SessionStore {

    enum StoreError: Error, CustomStringConvertible {
        case cannotCreateDirectory(String)
        case cannotWriteHeader(String)

        var description: String {
            switch self {
            case .cannotCreateDirectory(let s): return "could not create the session directory: \(s)"
            case .cannotWriteHeader(let s):     return "could not write the session header: \(s)"
            }
        }
    }

    static var sessionsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func directory(for sessionId: String) -> URL {
        sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// `20260808T142211Z` — the same stamp that prefixes every frame filename,
    /// so a frame pulled loose by a careless transfer still names its session.
    static func makeSessionId(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Creates the session directory and writes the header before any frame is
    /// captured — so a session interrupted before its first frame still leaves
    /// a record of what the device could do.
    @discardableResult
    static func open(capability: CapabilityReport, now: Date = Date()) throws -> SessionRecord {
        let record = SessionRecord(
            sessionId: makeSessionId(now),
            openedAt: now,
            openedAtUptime: ProcessInfo.processInfo.systemUptime,
            capability: capability)

        let dir = directory(for: record.sessionId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw StoreError.cannotCreateDirectory(error.localizedDescription)
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: dir.appendingPathComponent("session.json"))
        } catch {
            throw StoreError.cannotWriteHeader(error.localizedDescription)
        }

        return record
    }

    /// `20260808T142211Z_s001_b03_f02_1x.dng` (#9). The session stamp is
    /// repeated in every frame name so a file pulled loose by a careless
    /// transfer still says which session, station, bracket and sensor it is
    /// from. Extension lowercase, always.
    static func frameFilename(sessionId: String, station: Int, bracket: Int,
                              frame: Int, sensor: String) -> String {
        String(format: "%@_s%03d_b%02d_f%02d_%@.dng", sessionId, station, bracket, frame, sensor)
    }

    /// Frames are flat inside the session directory — no station/bracket
    /// nesting. Transfer paths flatten and AirDrop delivers loose files, and
    /// the structure is already in the log more reliably (#9).
    static func writeFrame(_ data: Data, named filename: String, sessionId: String) throws -> URL {
        let url = directory(for: sessionId).appendingPathComponent(filename)
        do {
            try data.write(to: url)
        } catch {
            throw StoreError.cannotWriteHeader("frame \(filename): \(error.localizedDescription)")
        }
        return url
    }

    /// The per-station write unit (#9). A station either completed or never
    /// existed (#10), so this is written once, at close — there is no partial
    /// station on disk to interpret later.
    static func writeStation(_ station: StationRecord) throws {
        let name = String(format: "station-%03d.json", station.stationIndex)
        let url = directory(for: station.sessionId).appendingPathComponent(name)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(station).write(to: url)
        } catch {
            throw StoreError.cannotWriteHeader("\(name): \(error.localizedDescription)")
        }
    }

    /// The raw IMU stream for one station, one JSON object per line so a long
    /// station appends rather than rewrites, and a truncated file still parses
    /// up to its last complete line.
    @discardableResult
    static func writeMotionStream(_ samples: [MotionSample], sessionId: String, station: Int) throws -> String {
        let name = String(format: "motion-%03d.jsonl", station)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data()
        for s in samples {
            out.append(try encoder.encode(s))
            out.append(0x0A)
        }
        try out.write(to: directory(for: sessionId).appendingPathComponent(name))
        return name
    }

    /// A diagnostic result that belongs to the session but not to any station.
    static func writeProbe<T: Encodable>(_ value: T, named name: String, sessionId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory(for: sessionId).appendingPathComponent(name))
    }

    /// Deletes every frame belonging to one station. #10's single rule: a hard
    /// fault flags, aborts the station, and deletes that station's frames —
    /// stations already banked survive.
    static func deleteStationFrames(sessionId: String, station: Int) {
        let prefix = String(format: "%@_s%03d_", sessionId, station)
        let dir = directory(for: sessionId)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
        // The motion stream belongs to the station too: a station either
        // completed or never existed (#10), so nothing of it survives.
        let motion = dir.appendingPathComponent(String(format: "motion-%03d.jsonl", station))
        try? FileManager.default.removeItem(at: motion)
    }

    static func existingSessionIds() -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil)
        return (contents ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }
}
