import Foundation
import Darwin

/// Where the app's own state lives, as distinct from the user's data.
///
/// `UIFileSharingEnabled` exposes the **whole** of `Documents` to the Files app,
/// which is exactly what this app wants for sessions, logs and protocols —
/// those are the user's, and #11 makes Files the transfer route. It is not what
/// it wants for the shot list or the device profile: those are the app's own
/// bookkeeping, and putting them where they can be browsed, edited and deleted
/// offers a footgun for no benefit. Apple's guidance is explicit that files not
/// intended for user access belong elsewhere.
///
/// So the rule is a question about ownership, not about format: **would a
/// photographer recognise this file as something they made?** Sessions yes,
/// protocols yes, logs yes — they asked for those and may want to hand them
/// over. A cursor into a half-walked shot list, no.
enum AppStorage {

    struct Roots {
        let documents: URL
        let support: URL
        let isIsolated: Bool
    }

    enum IsolationError: Error {
        case missingTestOptIn
        case unverifiedTestLaunch
        case invalidUITestFlag
        case unsupportedUITestLaunch
    }

    /// A compile-time capability, never an environment assertion of support.
    static var supportsUILaunchIsolation: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Resolve once, before launch migrations, logging or any store can run.
    /// XCTest is loaded into the host by the test runner, not linked by the app.
    /// Runner environment markers also fail closed if storage is accessed before
    /// XCTest loads. UI-launched apps do not load XCTest, so their separate
    /// opt-in is permitted only by the compiled Debug simulator capability.
    private static let processRoots: Roots = {
        do {
            return try resolveRoots(
                environment: ProcessInfo.processInfo.environment,
                isXCTest: NSClassFromString("XCTestCase") != nil,
                supportsUITesting: supportsUILaunchIsolation)
        } catch {
            // Do not log via DebugLog here: it also depends on these roots.
            fatalError("AppStorage refused unsafe test storage: \(error)")
        }
    }()

    /// No environment value is ever interpreted as a storage path. Hosted tests
    /// must both load XCTest and opt in (Debug AND Release). The capability input
    /// makes unsupported UI launches testable; process selection above always
    /// derives it from the build, never from caller-supplied environment values.
    static func resolveRoots(environment: [String: String], isXCTest: Bool,
                             supportsUITesting: Bool = supportsUILaunchIsolation,
                             fileManager: FileManager = .default) throws -> Roots {
        let flag = environment["RAWFORGE_TEST_STORAGE"]
        let hasRunnerMarker = ["XCTestConfigurationFilePath", "XCTestBundlePath",
                               "XCTestBundleInjectPath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
        if isXCTest {
            guard flag == "1" else { throw IsolationError.missingTestOptIn }
        } else {
            guard flag == nil && !hasRunnerMarker else {
                throw IsolationError.unverifiedTestLaunch
            }
        }
        let uiFlag = environment["RAWFORGE_UI_TESTING"]
        if let uiFlag {
            guard uiFlag == "1" else { throw IsolationError.invalidUITestFlag }
            guard supportsUITesting else { throw IsolationError.unsupportedUITestLaunch }
        }
        if !isXCTest && uiFlag == nil {
            // Preserve normal launch locations and lazy support-dir creation.
            return Roots(
                documents: fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0],
                support: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                isIsolated: false)
        }
        // mkdtemp atomically creates a fresh private directory (0700). Unlike a
        // caller-supplied path or a reusable name, it cannot adopt old app data.
        var template = fileManager.temporaryDirectory
            .appendingPathComponent("RAWForge-XCTest-XXXXXX").path.utf8CString
        let sandbox: URL = try template.withUnsafeMutableBufferPointer { buffer in
            guard let path = mkdtemp(buffer.baseAddress!) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        let roots = Roots(
            documents: sandbox.appendingPathComponent("Documents", isDirectory: true),
            support: sandbox.appendingPathComponent("Library/Application Support", isDirectory: true),
            isIsolated: true)
        // Any setup failure propagates to the process gate. Never return live
        // roots, migrate live files, or clear a previous run to make tests work.
        try fileManager.createDirectory(at: roots.documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: roots.support, withIntermediateDirectories: true)
        return roots
    }

    /// `Library/Application Support/`, created on first use.
    ///
    /// Backed up by iCloud and not purgeable, which is right for both files
    /// here — losing a device profile means re-measuring, and losing a shot
    /// list mid-shoot means re-authoring it at the pose.
    static var supportDirectory: URL {
        let base = processRoots.support
        if !processRoots.isIsolated {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static func supportFile(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }

    /// The user's data, and only that. Shared to Files wholesale.
    static var documentsDirectory: URL {
        processRoots.documents
    }

    /// Moves a file out of `Documents` on first launch after the split.
    ///
    /// An install that predates this change already has these files in the old
    /// place, and silently starting fresh would lose a device profile that cost
    /// twenty seconds of measurement and a shot list somebody authored. The
    /// move is one-way and idempotent: once the new file exists it wins, and a
    /// stray old copy is removed rather than left to confuse the next reader.
    @discardableResult
    static func migrateFromDocuments(_ name: String) -> Bool {
        let old = documentsDirectory.appendingPathComponent(name)
        let new = supportFile(name)
        let fm = FileManager.default

        guard fm.fileExists(atPath: old.path) else { return false }
        if fm.fileExists(atPath: new.path) {
            // Both exist: the new location is authoritative, so the old copy is
            // a leftover rather than a second opinion.
            try? fm.removeItem(at: old)
            logInfo(.store, "removed a stale \(name) left in Documents")
            return false
        }
        do {
            try fm.moveItem(at: old, to: new)
            logInfo(.store, "moved \(name) out of Documents into Application Support")
            return true
        } catch {
            logFailure(.store, "moving \(name) out of Documents", error)
            return false
        }
    }

    /// Everything that has to move, in one place so the migration and the tests
    /// cannot drift apart.
    static let filesMovedOutOfDocuments = ["shot-list.json", "device-profile.json"]

    static func migrateAll() {
        for name in filesMovedOutOfDocuments { migrateFromDocuments(name) }
    }
}
