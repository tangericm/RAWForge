import Foundation
import os

/// The app's flight recorder.
///
/// The instrument is used in the field, on one device, by one person, and the
/// failures that matter — a capture the pipeline refuses, a session that will
/// not start, a frame that never lands — happen once and cannot be reproduced
/// on a desk. `status` strings are no substitute: each one overwrites the last,
/// so by the time something is noticed the evidence is gone.
///
/// So every consequential act writes here, and the log outlives the run:
///
/// - **In memory** — a ring the console screen tails live, so a problem can be
///   read at the pose rather than after the walk back.
/// - **On disk** — one file per launch under `Documents/logs-v2`, which puts it in
///   the same place as the sessions and out the same route (#11: Files, or a
///   cable). The versioned directory cannot enumerate legacy raw-uptime logs.
///   The last few launches are kept; older ones are swept.
/// - **In the unified log** — mirrored to `os.Logger`, so a device attached to
///   Console.app or `devicectl` shows the same stream with no export step.
///
/// Nothing here is load-bearing for capture. Logging must never be the reason a
/// station fails, so every path is best-effort and silent on its own errors.
final class DebugLog: @unchecked Sendable {

    static let shared = DebugLog()

    // MARK: - Shape of an entry

    enum Level: Int, Comparable, CaseIterable {
        case trace, info, warn, error

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .trace: return "TRACE"
            case .info:  return "INFO"
            case .warn:  return "WARN"
            case .error: return "ERROR"
            }
        }

        /// Short enough to sit in a filter control without wrapping.
        var short: String {
            switch self {
            case .trace: return "Trace"
            case .info:  return "Info"
            case .warn:  return "Warn"
            case .error: return "Error"
            }
        }
    }

    /// Named after the subsystem that failed, not the file that logged it — the
    /// question at the pose is "did the rig refuse or did the write fail", and
    /// these are the answers to it.
    enum Category: String, CaseIterable {
        case app, rig, capture, flow, store, motion, export, probe, ui
    }

    struct Entry: Identifiable {
        let id: UInt64
        let at: Date
        let elapsedSinceLaunch: TimeInterval
        let level: Level
        let category: Category
        let message: String

        /// `12:04:33.182` — a wall clock, because it is read against when the
        /// operator remembers something going wrong.
        var clock: String {
            DebugLog.clockFormatter.string(from: at)
        }

        var line: String {
            String(format: "%@ +%.3fs %-5@ %-7@ %@",
                   clock, elapsedSinceLaunch, level.label as NSString,
                   category.rawValue as NSString, message)
        }

        /// The durable/exported form deliberately omits wall clock. Diagnostic
        /// files carry only launch-relative time so they cannot disclose when
        /// the operator used the app.
        var persistedLine: String {
            String(format: "+%.3fs %-5@ %-7@ %@",
                   elapsedSinceLaunch, level.label as NSString,
                   category.rawValue as NSString, message)
        }
    }

    // MARK: - Storage

    /// Deep enough to hold a full three-sensor station with every frame's
    /// arrival in it, so the console still shows the beginning of a station
    /// after the end of it.
    private static let ringCapacity = 4_000

    private let lock = NSLock()
    private var ring: [Entry] = []
    private var nextID: UInt64 = 0
    /// Bumped on every write so a view can tell "nothing new" cheaply rather
    /// than diffing four thousand entries at 2 Hz.
    private var generationCounter: UInt64 = 0
    private var counts: [Level: Int] = [:]

    private let io = DispatchQueue(label: "com.tangericm.rawforge.debuglog", qos: .utility)
    private var handle: FileHandle?
    private let osLog = Logger(subsystem: "com.tangericm.rawforge", category: "rawforge")
    private let storageDirectory: URL
    private let backupExclusion: (URL) throws -> Void
    private let uptime: () -> TimeInterval
    private var launchOriginUptime: TimeInterval
    private var runMarkerURL: URL?

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(
        storageDirectory: URL = DebugLog.directory,
        backupExclusion: @escaping (URL) throws -> Void = DebugLog.excludeFromBackup,
        uptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.storageDirectory = storageDirectory
        self.backupExclusion = backupExclusion
        self.uptime = uptime
        launchOriginUptime = uptime()
    }

    // MARK: - Files

    static var directory: URL {
        AppStorage.documentsDirectory
            .appendingPathComponent("logs-v2", isDirectory: true)
    }

    /// Kept separate so migration can quarantine legacy raw-uptime reports
    /// without ever placing them in a current-report share surface.
    static var legacyDirectory: URL {
        AppStorage.documentsDirectory
            .appendingPathComponent("logs", isDirectory: true)
    }

    private(set) var fileURL: URL?

    /// Kept small on purpose. The log is a debugging aid, not a record — the
    /// sessions are the record — and a field device's storage belongs to
    /// frames.
    private static let launchesKept = 8

    // MARK: - Lifecycle

    /// Opens this launch's file, notes whether the previous run ended cleanly,
    /// and writes a header naming the device.
    ///
    /// The clean-exit marker is the cheapest possible crash detector: a file
    /// that exists while the app is alive and is removed when it resigns
    /// normally. Finding one at launch means the last run was killed — which is
    /// exactly what an out-of-range zoom or an unhandled AVFoundation exception
    /// does, and neither leaves anything else behind.
    func start(device: DeviceIdentity) {
        launchOriginUptime = uptime()
        let stamp = Self.stampFormatter.string(from: Date())
        var persistenceError: Error?
        var unclean = false
        var launchURL: URL?

        handle = nil
        fileURL = nil
        runMarkerURL = nil
        do {
            try backupExclusion(storageDirectory)

            let url = storageDirectory.appendingPathComponent("rawforge-\(stamp).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw PersistenceError.couldNotCreateLaunchLog
            }
            do {
                handle = try FileHandle(forWritingTo: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            fileURL = url
            launchURL = url

            let marker = storageDirectory.appendingPathComponent(".running")
            unclean = FileManager.default.fileExists(atPath: marker.path)
            if FileManager.default.createFile(atPath: marker.path, contents: Data()) {
                runMarkerURL = marker
            }
            sweepOldLogs()
        } catch {
            // Privacy fails closed: the ring and unified log remain available,
            // but no launch report exists unless exclusion was verified first.
            handle = nil
            fileURL = nil
            persistenceError = error
        }

        write(.info, .app, "RAWForge \(device.buildDescription) launched")
        if let persistenceError {
            write(.error, .store,
                  "diagnostic persistence unavailable; logging in memory only — "
                  + "\(persistenceError)")
        }
        if device.isDirtyBuild {
            write(.warn, .app, "built from a working tree with uncommitted changes — this "
                  + "binary matches no commit in the history")
        }
        write(.info, .app, "\(device.modelIdentifier) · \(device.systemName) \(device.systemVersion)"
              + (device.isSimulator ? " · SIMULATOR" : ""))
        if let launchURL {
            write(.info, .app, "log file \(launchURL.lastPathComponent)")
        }
        if unclean {
            write(.error, .app, "the previous run did not exit cleanly — it was killed or crashed. "
                  + "The log before this one holds whatever it managed to write.")
        }
        installExceptionHandler()
    }

    /// Reapplied at every launch so retained reports as well as this launch's
    /// file remain outside iCloud Backup. Creating the directory first covers
    /// upgrades without moving or replacing any retained safe-format logs.
    private static func excludeFromBackup(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)

        let verified = try mutableDirectory.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        guard verified.isExcludedFromBackup == true else {
            throw PersistenceError.backupExclusionWasNotApplied
        }
    }

    private enum PersistenceError: Error {
        case backupExclusionWasNotApplied
        case couldNotCreateLaunchLog
    }

    /// Called when the app resigns normally, so the next launch can tell a
    /// clean exit from a kill.
    func noteCleanExit() {
        write(.info, .app, "app resigned cleanly")
        flush()
        if let runMarkerURL {
            try? FileManager.default.removeItem(at: runMarkerURL)
            self.runMarkerURL = nil
        }
    }

    /// An ObjC exception is the one failure mode this app is known to hit —
    /// a Bayer capture at a zoom factor other than 1.0 terminates the process
    /// rather than returning an error. Swift cannot catch it, but it can be
    /// written down on the way out.
    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let log = DebugLog.shared
            log.write(.error, .app, "UNCAUGHT \(exception.name.rawValue): "
                      + (exception.reason ?? "no reason given"))
            for frame in exception.callStackSymbols.prefix(24) {
                log.write(.error, .app, "  \(frame)")
            }
            log.flush()
        }
    }

    private func sweepOldLogs() {
        io.async {
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: self.storageDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in files.dropFirst(Self.launchesKept) {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }

    // MARK: - Writing

    func write(_ level: Level, _ category: Category, _ message: @autoclosure () -> String) {
        let text = message()
        let entry: Entry
        lock.lock()
        nextID += 1
        generationCounter += 1
        counts[level, default: 0] += 1
        entry = Entry(id: nextID, at: Date(),
                      elapsedSinceLaunch: max(0, uptime() - launchOriginUptime),
                      level: level, category: category, message: text)
        ring.append(entry)
        // Trimmed in blocks rather than one at a time. `removeFirst(1)` on a
        // full array shifts every remaining element, which would put an O(n)
        // memmove on the capture path for every trace line of a 300-frame run;
        // dropping a quarter at once amortises that to nothing.
        if ring.count > Self.ringCapacity {
            ring.removeFirst(Self.ringCapacity / 4)
        }
        lock.unlock()

        switch level {
        case .trace: osLog.debug("\(category.rawValue, privacy: .public) \(text, privacy: .public)")
        case .info:  osLog.info("\(category.rawValue, privacy: .public) \(text, privacy: .public)")
        case .warn:  osLog.warning("\(category.rawValue, privacy: .public) \(text, privacy: .public)")
        case .error: osLog.error("\(category.rawValue, privacy: .public) \(text, privacy: .public)")
        }

        let line = entry.persistedLine + "\n"
        io.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            try? self?.handle?.write(contentsOf: data)
        }
    }

    /// Records a thrown error with the operation that threw it, which is the
    /// pair that actually identifies a fault. `error` alone reads as noise a
    /// week later.
    func failure(_ category: Category, _ operation: String, _ error: Error) {
        write(.error, category, "\(operation) failed — \(error)")
    }

    func flush() {
        io.sync { try? handle?.synchronize() }
    }

    /// The current report is shareable only after pending writes have reached
    /// a real file. Both settings and the console use this same boundary.
    func currentReportURL() -> URL? {
        flush()
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    // MARK: - Reading

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generationCounter
    }

    func snapshot(minimum: Level = .trace, categories: Set<Category>? = nil,
                  search: String = "") -> [Entry] {
        lock.lock()
        let all = ring
        lock.unlock()
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { e in
            e.level >= minimum
                && (categories.map { $0.contains(e.category) } ?? true)
                && (needle.isEmpty || e.message.lowercased().contains(needle))
        }
    }

    /// For the header of the console: the count that matters is how many
    /// things went wrong, not how many lines were written.
    func tally() -> (warnings: Int, errors: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return (counts[.warn] ?? 0, counts[.error] ?? 0, ring.count)
    }

    /// Every log file, newest first — the current run's included, since a
    /// problem worth exporting is usually the one just seen.
    static func allFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func clearRing() {
        lock.lock()
        ring.removeAll()
        counts.removeAll()
        lock.unlock()
        write(.info, .app, "console cleared — the file on disk still holds everything")
    }
}

/// Shorthand at the call sites, so instrumenting a line costs one line.
///
/// Deliberately free functions: a capture path that has to reach through a
/// singleton to say what it just did tends not to say it.
@inline(__always) func logTrace(_ c: DebugLog.Category, _ m: @autoclosure () -> String) {
    DebugLog.shared.write(.trace, c, m())
}
@inline(__always) func logInfo(_ c: DebugLog.Category, _ m: @autoclosure () -> String) {
    DebugLog.shared.write(.info, c, m())
}
@inline(__always) func logWarn(_ c: DebugLog.Category, _ m: @autoclosure () -> String) {
    DebugLog.shared.write(.warn, c, m())
}
@inline(__always) func logError(_ c: DebugLog.Category, _ m: @autoclosure () -> String) {
    DebugLog.shared.write(.error, c, m())
}
@inline(__always) func logFailure(_ c: DebugLog.Category, _ op: String, _ e: Error) {
    DebugLog.shared.failure(c, op, e)
}
