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
        case cannotExcludeFromBackup(String)
        case cannotWriteHeader(String)

        var description: String {
            switch self {
            case .cannotCreateDirectory(let s): return "could not create the session directory: \(s)"
            case .cannotExcludeFromBackup(let s): return "could not verify backup exclusion: \(s)"
            case .cannotWriteHeader(let s):     return "could not write the session header: \(s)"
            }
        }
    }

    struct BackupExclusion {
        let applyAndVerify: (URL) throws -> Bool

        init(_ applyAndVerify: @escaping (URL) throws -> Bool) {
            self.applyAndVerify = applyAndVerify
        }

        static let live = BackupExclusion { url in
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
            let verified = try target.resourceValues(
                forKeys: [.isExcludedFromBackupKey])
            return verified.isExcludedFromBackup == true
        }
    }

    static var sessionsRoot: URL {
        AppStorage.documentsDirectory
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
        let url = AppStorage.documentsDirectory
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
                     calibration: (id: String, ageSeconds: Double)? = nil,
                     backupExclusion: BackupExclusion = .live) throws -> SessionRecord {
        let record = SessionRecord(
            sessionId: makeSessionId(now),
            openedAt: now,
            capability: capability,
            availableCapacityBytes: availableCapacityBytes(),
            sessionType: sessionType,
            calibrationSessionId: calibration?.id,
            calibrationAgeSeconds: calibration?.ageSeconds)

        // Backup exclusion is a privacy precondition for capture. Create only
        // the empty root, set the value, and read it back before creating any
        // session directory or writing its header/data.
        do {
            try FileManager.default.createDirectory(
                at: sessionsRoot, withIntermediateDirectories: true)
        } catch {
            throw StoreError.cannotCreateDirectory(error.localizedDescription)
        }

        let exclusionVerified: Bool
        do {
            exclusionVerified = try backupExclusion.applyAndVerify(sessionsRoot)
        } catch {
            throw StoreError.cannotExcludeFromBackup(error.localizedDescription)
        }
        guard exclusionVerified else {
            throw StoreError.cannotExcludeFromBackup(
                "the sessions root did not report isExcludedFromBackup=true")
        }

        let dir = directory(for: record.sessionId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
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
        loadStationsDetailed(sessionId, sessionsRoot: sessionsRoot)
    }

    private static func loadStationsDetailed(
        _ sessionId: String,
        sessionsRoot: URL
    ) -> (stations: [StationRecord], unreadable: [String]) {
        let dir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
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
    /// The station invariant says that a phone death must take an unfinished
    /// station with it. Holding hundreds of megabytes of DNGs in RAM to achieve
    /// that would be jetsam bait, so frames are written through and this sweep
    /// restores the same guarantee at launch: a frame whose station has no
    /// record is a station that never existed, and it goes.
    ///
    /// Runs before anything else reads the sessions directory, so no orphan is
    /// ever visible in the browser or counted in a capacity estimate.
    struct OrphanCleanupCandidate: Hashable {
        let relativePath: String
        let url: URL
        let countsTowardDisclosure: Bool
    }

    static func orphanCleanupCandidates(
        sessionsRoot: URL = sessionsRoot
    ) -> [OrphanCleanupCandidate] {
        var candidates: [OrphanCleanupCandidate] = []
        for sessionId in existingSessionIds(at: sessionsRoot) {
            let dir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            let sessionURL = dir.appendingPathComponent("session.json")
            guard let sessionData = try? Data(contentsOf: sessionURL),
                  (try? decoder.decode(SessionRecord.self, from: sessionData)) != nil else {
                // An unknown, malformed, or not-yet-migrated header may carry
                // ownership facts that this build cannot interpret. Deleting
                // anything from that directory would turn uncertainty into
                // data loss.
                continue
            }
            let ownedStations = Set(files.compactMap(stationIndexOwnedByMetadataFilename))
            // Dark calibration frames use the distinct `_d..._r...` grammar and
            // therefore never enter station ownership cleanup.
            for file in files where file.pathExtension == "dng" {
                guard (try? file.resourceValues(
                    forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard let frame = parseFrameFilename(
                    file.lastPathComponent, sessionId: sessionId),
                    !ownedStations.contains(frame.station) else { continue }
                let relativePath = "\(sessionId)/\(file.lastPathComponent)"
                guard let candidate = validatedOrphanCleanupCandidate(
                    relativePath: relativePath,
                    sessionsRoot: sessionsRoot) else { continue }
                candidates.append(candidate)
            }
            for file in files where file.pathExtension == "jsonl" {
                guard (try? file.resourceValues(
                    forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard let station = motionStationIndex(file.lastPathComponent),
                      !ownedStations.contains(station) else { continue }
                let relativePath = "\(sessionId)/\(file.lastPathComponent)"
                guard let candidate = validatedOrphanCleanupCandidate(
                    relativePath: relativePath,
                    sessionsRoot: sessionsRoot) else { continue }
                candidates.append(candidate)
            }
        }
        return candidates.sorted { $0.relativePath < $1.relativePath }
    }

    static func validatedOrphanCleanupCandidate(
        relativePath: String,
        sessionsRoot: URL
    ) -> OrphanCleanupCandidate? {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let sessionId = String(components[0])
        let filename = String(components[1])
        guard !sessionId.isEmpty, sessionId != ".", sessionId != "..",
              !filename.isEmpty, filename != ".", filename != ".." else { return nil }

        let countsTowardDisclosure: Bool
        if parseFrameFilename(filename, sessionId: sessionId) != nil {
            countsTowardDisclosure = true
        } else if motionStationIndex(filename) != nil {
            countsTowardDisclosure = false
        } else {
            return nil
        }

        let root = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let url = sessionsRoot
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(filename)
            .standardizedFileURL
        // iOS may leave an aliased /var path unresolved once the leaf is gone.
        // A cleanup journal intentionally includes those already-deleted files.
        // Resolve the existing parent first, then append the potentially absent leaf.
        let parent = root.appendingPathComponent(sessionId, isDirectory: true)
            .resolvingSymlinksInPath()
        guard parent.path.hasPrefix(root.path + "/") else { return nil }
        let candidate = parent.appendingPathComponent(filename)
        // Reject dangling links too; fileExists alone cannot distinguish them
        // from a journal candidate whose deletion already completed.
        guard (try? FileManager.default.destinationOfSymbolicLink(
            atPath: candidate.path)) == nil else { return nil }
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        return OrphanCleanupCandidate(
            relativePath: relativePath,
            url: url,
            countsTowardDisclosure: countsTowardDisclosure)
    }

    @discardableResult
    static func sweepOrphanedFrames(
        sessionsRoot: URL = sessionsRoot,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Int {
        var removed = 0
        for candidate in orphanCleanupCandidates(sessionsRoot: sessionsRoot) {
            do {
                try removeItem(candidate.url)
                if candidate.countsTowardDisclosure { removed += 1 }
            } catch {
                // The caller reports successful frame deletion only.
            }
        }
        return removed
    }

    private struct FrameFilenameParts {
        let station: Int
    }

    /// Parses the complete generated frame grammar. Widths in the formatter are
    /// minimums, so structural delimiters — not fixed-width prefixes — bound
    /// every numeric component.
    private static func parseFrameFilename(
        _ filename: String,
        sessionId: String
    ) -> FrameFilenameParts? {
        guard filename.hasSuffix(".dng") else { return nil }
        let stem = filename.dropLast(".dng".count)
        let prefix = "\(sessionId)_s"
        guard stem.hasPrefix(prefix) else { return nil }
        let afterPrefix = stem.dropFirst(prefix.count)
        guard let bracketDelimiter = afterPrefix.range(of: "_b") else { return nil }
        let stationComponent = afterPrefix[..<bracketDelimiter.lowerBound]
        guard stationComponent.count >= 3,
              let station = decimalInteger(stationComponent) else {
            return nil
        }
        let afterBracketDelimiter = afterPrefix[bracketDelimiter.upperBound...]
        guard let frameDelimiter = afterBracketDelimiter.range(of: "_f") else { return nil }
        let bracketComponent = afterBracketDelimiter[..<frameDelimiter.lowerBound]
        guard bracketComponent.count >= 2,
              decimalInteger(bracketComponent) != nil else {
            return nil
        }
        let afterFrameDelimiter = afterBracketDelimiter[frameDelimiter.upperBound...]
        guard let sensorDelimiter = afterFrameDelimiter.firstIndex(of: "_") else { return nil }
        let frameComponent = afterFrameDelimiter[..<sensorDelimiter]
        guard frameComponent.count >= 2,
              decimalInteger(frameComponent) != nil,
              !afterFrameDelimiter[afterFrameDelimiter.index(after: sensorDelimiter)...].isEmpty else {
            return nil
        }
        return FrameFilenameParts(station: station)
    }

    private static func motionStationIndex(_ filename: String) -> Int? {
        guard filename.hasPrefix("motion-"), filename.hasSuffix(".jsonl") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: "motion-".count)
        let end = filename.index(filename.endIndex, offsetBy: -".jsonl".count)
        let stationComponent = filename[start..<end]
        guard stationComponent.count >= 3 else { return nil }
        return decimalInteger(stationComponent)
    }

    private static func decimalInteger<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        return Int(text)
    }

    private static func stationIndexOwnedByMetadataFilename(_ url: URL) -> Int? {
        guard url.pathExtension == "json" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("station-") else { return nil }
        return decimalInteger(stem.dropFirst("station-".count))
    }

    static func existingSessionIds() -> [String] {
        existingSessionIds(at: sessionsRoot)
    }

    private static func existingSessionIds(at sessionsRoot: URL) -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil)
        return (contents ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }
}
