import ImageIO
import UIKit
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

    /// Measured budget from #11: 1,675 real iPhone DNGs averaged 10.0 MB with a
    /// maximum of 30.7 MB. The average sizes a pre-flight estimate; the maximum
    /// is what a worst case should be checked against.
    static let averageFrameBytes: Int64 = 10_000_000
    static let worstCaseFrameBytes: Int64 = 30_700_000

    /// The conservative figure, deliberately **not**
    /// `volumeAvailableCapacityForImportantUsage` (#11) — that one counts
    /// purgeable space the system may or may not actually release, which is the
    /// wrong number to promise a field session against.
    static func availableCapacityBytes() -> Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
    }

    /// Storage exhausted is a hard fault (#10). Checked before a station fires
    /// rather than discovered mid-write, so the station never half-exists.
    static func hasRoom(forFrames n: Int) -> Bool {
        guard let free = availableCapacityBytes() else { return true }
        return free > Int64(n) * worstCaseFrameBytes
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
    static func open(capability: CapabilityReport, now: Date = Date(),
                     sessionType: String = "scene",
                     calibration: (id: String, ageSeconds: Double)? = nil) throws -> SessionRecord {
        let record = SessionRecord(
            sessionId: makeSessionId(now),
            openedAt: now,
            openedAtUptime: ProcessInfo.processInfo.systemUptime,
            capability: capability,
            availableCapacityBytes: availableCapacityBytes(),
            sessionType: sessionType,
            calibrationSessionId: calibration?.id,
            calibrationAgeSeconds: calibration?.ageSeconds)

        let dir = directory(for: record.sessionId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw StoreError.cannotCreateDirectory(error.localizedDescription)
        }

        // #11: a ten-station scene runs to ~2 GB, and without this every one of
        // those bytes goes into every iCloud backup. Set on the sessions root
        // so it covers sessions not yet created.
        var root = sessionsRoot
        var flag = URLResourceValues()
        flag.isExcludedFromBackup = true
        try? root.setResourceValues(flag)

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

    // MARK: - Reading back, for the log browser (#12)

    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    static func loadSession(_ sessionId: String) -> SessionRecord? {
        let url = directory(for: sessionId).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    /// Stations that parsed, and the names of any that did not.
    ///
    /// A file that fails to decode used to vanish silently, which is the worst
    /// possible handling: the browser would show four stations where five were
    /// shot and nothing would say so. An unreadable record is a fact about the
    /// session and belongs on screen.
    static func loadStationsDetailed(_ sessionId: String) -> (stations: [StationRecord], unreadable: [String]) {
        let dir = directory(for: sessionId)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var stations: [StationRecord] = []
        var unreadable: [String] = []
        for f in files where f.lastPathComponent.hasPrefix("station-") && f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let record = try? decoder.decode(StationRecord.self, from: data) else {
                unreadable.append(f.lastPathComponent); continue
            }
            stations.append(record)
        }
        return (stations.sorted { $0.stationIndex < $1.stationIndex }, unreadable.sorted())
    }

    static func loadStations(_ sessionId: String) -> [StationRecord] {
        loadStationsDetailed(sessionId).stations
    }

    /// #11 makes the session directory the unit that is moved and the unit that
    /// is deleted once transferred. Without this the only way to reclaim space
    /// is to delete the whole app, which takes the protocols and every other
    /// session with it.
    ///
    /// Deliberately unguarded by an "exported?" check: #11 removed
    /// exported/unexported tracking, and a flag the app cannot keep honest is
    /// worse than none. The confirmation lives in the UI, where the operator
    /// can see what they are about to lose.
    static func deleteSession(_ sessionId: String) throws {
        try FileManager.default.removeItem(at: directory(for: sessionId))
    }

    static func frameAndStationCount(sessionId: String) -> (stations: Int, frames: Int, megabytes: Int) {
        let dir = directory(for: sessionId)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let frames = files.filter { $0.pathExtension == "dng" }
        let bytes = frames.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
        let stations = files.filter { $0.lastPathComponent.hasPrefix("station-") && $0.pathExtension == "json" }
        return (stations.count, frames.count, bytes / 1_000_000)
    }

    /// The DNG's **own** embedded preview. `CreateThumbnailFromImageIfAbsent` is
    /// deliberately false: #12 allows reading a thumbnail that exists and
    /// forbids generating one, because generating it would mean demosaicing the
    /// Bayer payload and putting a tone-mapped picture on screen while
    /// appearing to show the data being kept.
    static func embeddedThumbnail(sessionId: String, filename: String, maxPixel: Int = 160) -> UIImage? {
        let url = directory(for: sessionId).appendingPathComponent(filename)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The most recent calibration session on disk, with its age, so a scene
    /// session can reference it (#15).
    static func latestCalibration(now: Date = Date()) -> (id: String, ageSeconds: Double)? {
        for id in existingSessionIds().reversed() {
            guard let r = loadSession(id), r.sessionType == "calibration" else { continue }
            return (id, now.timeIntervalSince(r.openedAt))
        }
        return nil
    }

    /// A calibration run writes one file per `(shutter, ISO)` setting, because
    /// that is its abort unit (#15) — a fault costs one chunk and the run
    /// resumes, rather than discarding 336 frames.
    static func writeDarkSetting(_ record: DarkSettingRecord, sessionId: String, index: Int) throws {
        let name = String(format: "dark-%03d.json", index)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory(for: sessionId).appendingPathComponent(name))
    }

    /// Deletes the frames of one dark setting. Named by the same prefix the
    /// filenames carry, so an abandoned setting leaves nothing behind.
    static func deleteDarkSettingFrames(sessionId: String, setting: Int) {
        let prefix = String(format: "%@_d%03d_", sessionId, setting)
        let dir = directory(for: sessionId)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// `<session>_d004_r02_1x.dng` — setting, repeat, sensor. A dark frame has
    /// no station and no bracket, so it does not borrow that naming.
    static func darkFrameFilename(sessionId: String, setting: Int, repeatIndex: Int, sensor: String) -> String {
        String(format: "%@_d%03d_r%02d_%@.dng", sessionId, setting, repeatIndex, sensor)
    }

    /// Removes frames belonging to a station that never closed.
    ///
    /// The prototype buffers a station in memory so that a phone death takes it
    /// with it — *"nothing was written; the buffered station goes with it."*
    /// Holding 240 MB of DNGs in RAM to achieve that would be jetsam bait, so
    /// frames are written through and this sweep restores the same guarantee at
    /// launch: a frame whose station has no record is a station that never
    /// existed, and it goes.
    ///
    /// Runs before anything else reads the sessions directory, so no orphan is
    /// ever visible in the browser or counted in a capacity estimate.
    @discardableResult
    static func sweepOrphanedFrames() -> Int {
        var removed = 0
        for sessionId in existingSessionIds() {
            let dir = directory(for: sessionId)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let closedStations = Set(loadStations(sessionId).map(\.stationIndex))
            // Calibration runs write per setting, not per station, and are the
            // documented carve-out (#15) — their frames are never orphans.
            let darkSettings = files.filter { $0.lastPathComponent.hasPrefix("dark-") }
            for f in files where f.pathExtension == "dng" {
                let name = f.lastPathComponent
                if !darkSettings.isEmpty, name.contains("_d") { continue }
                guard let r = name.range(of: "_s"),
                      let station = Int(name[r.upperBound...].prefix(3)) else { continue }
                if !closedStations.contains(station) {
                    try? FileManager.default.removeItem(at: f)
                    removed += 1
                }
            }
        }
        return removed
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
