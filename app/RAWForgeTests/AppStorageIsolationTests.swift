import XCTest
@testable import RAWForge

/// These initial assertions are read-only: safe even when detecting a regression.
final class AppStorageIsolationTests: XCTestCase {
    private let optIn = ["RAWFORGE_TEST_STORAGE": "1"]

    func testXCTestProcessUsesIsolatedRoots() {
        let fm = FileManager.default
        XCTAssertEqual(ProcessInfo.processInfo.environment["RAWFORGE_TEST_STORAGE"], "1",
                       "The scheme Test action must opt in, including Release")
        print("ISOLATION_CONTEXT class=\(NSClassFromString("XCTestCase") != nil) keys=\(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("XCTest") }.sorted())")
        let documents = AppStorage.documentsDirectory.resolvingSymlinksInPath()
        let support = AppStorage.supportDirectory.resolvingSymlinksInPath()
        XCTAssertNotEqual(documents, fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath())
        XCTAssertNotEqual(support, fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath())
        XCTAssertTrue(documents.path.hasPrefix(fm.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        XCTAssertEqual(documents.deletingLastPathComponent(), support.deletingLastPathComponent()
            .deletingLastPathComponent())
        XCTAssertEqual(AppStorage.documentsDirectory, AppStorage.documentsDirectory,
                       "Every store must share one immutable root for the process")
        print("ISOLATION_ROOT \(documents.deletingLastPathComponent().path)")
    }

    func testAllDefaultStoreRootsAreInsideIsolatedDocuments() {
        let documents = AppStorage.documentsDirectory
        XCTAssertEqual(SessionStore.sessionsRoot, documents.appendingPathComponent("sessions", isDirectory: true))
        XCTAssertEqual(ProtocolLibrary.directory, documents.appendingPathComponent("protocols", isDirectory: true))
        XCTAssertEqual(DebugLog.directory, documents.appendingPathComponent("logs-v2", isDirectory: true))
        XCTAssertEqual(DebugLog.legacyDirectory, documents.appendingPathComponent("logs", isDirectory: true))
    }

    func testLaunchMaintenanceAndSharedLoggerAlreadyUsedIsolation() throws {
        let log = try XCTUnwrap(DebugLog.shared.fileURL)
        XCTAssertEqual(log.deletingLastPathComponent(), DebugLog.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            AppStorage.supportFile("privacy-migration-v1.json").path))
    }

    func testNormalLaunchSelectsUnchangedSystemDirectoriesWithoutCreatingAnything() throws {
        let fm = RefusingDirectoryCreation(failOnCall: 1)
        let roots = try AppStorage.resolveRoots(environment: [:], isXCTest: false, fileManager: fm)
        XCTAssertFalse(roots.isIsolated)
        XCTAssertEqual(roots.documents, FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        XCTAssertEqual(roots.support, FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        XCTAssertEqual(fm.calls, 0, "Normal root selection must not create a test sandbox")
    }

    #if DEBUG && targetEnvironment(simulator)
    func testUILaunchWithoutXCTestCreatesFreshPrivateRootsWithoutAccessingOrdinaryRoots() throws {
        let fm = RefusingDirectoryCreation(failOnCall: 0)
        let environment = ["RAWFORGE_UI_TESTING": "1",
                           "RAWFORGE_UI_TEST_STORAGE_ROOT": "/must/not/be/used",
                           "RAWFORGE_TEST_STORAGE_ROOT": "/must/not/be/used"]
        let first = try AppStorage.resolveRoots(environment: environment, isXCTest: false, fileManager: fm)
        XCTAssertTrue(first.isIsolated)
        XCTAssertEqual(fm.ordinaryRootLookups, 0, "UI startup must not even resolve ordinary storage")
        // A failing implementation must never make this test write to or delete live data.
        guard first.isIsolated else { return }
        defer { removeCreatedSandbox(first) }
        let second = try AppStorage.resolveRoots(environment: environment, isXCTest: false, fileManager: fm)
        XCTAssertTrue(second.isIsolated)
        guard second.isIsolated else { return }
        defer { removeCreatedSandbox(second) }
        XCTAssertEqual(fm.ordinaryRootLookups, 0)
        XCTAssertNotEqual(first.documents, second.documents)
        for roots in [first, second] {
            let sandbox = roots.documents.deletingLastPathComponent()
            guard sandbox.lastPathComponent.hasPrefix("RAWForge-XCTest-"),
                  sandbox.deletingLastPathComponent().resolvingSymlinksInPath()
                    == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                  roots.support == sandbox.appendingPathComponent("Library/Application Support", isDirectory: true) else {
                return XCTFail("Refusing fixture writes outside a generated private sandbox")
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: sandbox.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
            for directory in [roots.documents, roots.support] {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
                let marker = directory.appendingPathComponent("ui-test-marker")
                try Data("private UI launch".utf8).write(to: marker)
                XCTAssertEqual(try Data(contentsOf: marker), Data("private UI launch".utf8))
            }
        }
    }
    #endif

    func testMalformedUIFlagFailsBeforeAccessingOrdinaryRootsOrCreatingStorage() {
        for value in ["", "0", " 1", "/tmp/arbitrary-user-path"] {
            for isXCTest in [false, true] {
                let fm = RefusingDirectoryCreation(failOnCall: 1)
                var environment = ["RAWFORGE_UI_TESTING": value]
                if isXCTest { environment.merge(optIn) { _, new in new } }
                XCTAssertThrowsError(try AppStorage.resolveRoots(
                    environment: environment, isXCTest: isXCTest,
                    supportsUITesting: true, fileManager: fm)) {
                    guard case AppStorage.IsolationError.invalidUITestFlag = $0 else {
                        return XCTFail("Expected invalid UI flag, got \($0)")
                    }
                }
                XCTAssertEqual(fm.calls, 0)
                XCTAssertEqual(fm.ordinaryRootLookups, 0)
            }
        }
    }

    func testUnsupportedBuildRejectsUIFlagButPreservesHostedXCTest() throws {
        for isXCTest in [false, true] {
            let fm = RefusingDirectoryCreation(failOnCall: 1)
            var environment = ["RAWFORGE_UI_TESTING": "1", "DEBUG": "1",
                               "SIMULATOR_UDID": "spoofed", "RAWFORGE_UI_TESTING_SUPPORTED": "1"]
            if isXCTest { environment.merge(optIn) { _, new in new } }
            XCTAssertThrowsError(try AppStorage.resolveRoots(
                environment: environment, isXCTest: isXCTest,
                supportsUITesting: false, fileManager: fm)) {
                guard case AppStorage.IsolationError.unsupportedUITestLaunch = $0 else {
                    return XCTFail("Expected unsupported UI launch, got \($0)")
                }
            }
            XCTAssertEqual(fm.calls, 0)
            XCTAssertEqual(fm.ordinaryRootLookups, 0)
        }
        let roots = try AppStorage.resolveRoots(environment: optIn, isXCTest: true, supportsUITesting: false)
        XCTAssertTrue(roots.isIsolated)
        guard roots.isIsolated else { return }
        removeCreatedSandbox(roots)
    }

    func testUIFlagCannotBypassHostedXCTestSafeguards() {
        for value in [nil, "0"] as [String?] {
            var environment = ["RAWFORGE_UI_TESTING": "1"]
            environment["RAWFORGE_TEST_STORAGE"] = value
            XCTAssertThrowsError(try AppStorage.resolveRoots(environment: environment, isXCTest: true)) {
                guard case AppStorage.IsolationError.missingTestOptIn = $0 else {
                    return XCTFail("Expected missing opt-in, got \($0)")
                }
            }
        }
        for key in ["RAWFORGE_TEST_STORAGE", "XCTestConfigurationFilePath"] {
            let fm = RefusingDirectoryCreation(failOnCall: 1)
            XCTAssertThrowsError(try AppStorage.resolveRoots(
                environment: ["RAWFORGE_UI_TESTING": "1", key: "1"], isXCTest: false,
                supportsUITesting: true, fileManager: fm)) {
                guard case AppStorage.IsolationError.unverifiedTestLaunch = $0 else {
                    return XCTFail("Expected unverified launch, got \($0)")
                }
            }
            XCTAssertEqual(fm.calls, 0)
            XCTAssertEqual(fm.ordinaryRootLookups, 0)
        }
    }

    func testUISandboxCreationFailureNeverFallsBackToOrdinaryRoots() throws {
        let fm = InvalidTemporaryDirectory()
        try Data().write(to: fm.blocker)
        defer { try? FileManager.default.removeItem(at: fm.blocker) }
        XCTAssertThrowsError(try AppStorage.resolveRoots(
            environment: ["RAWFORGE_UI_TESTING": "1"], isXCTest: false,
            supportsUITesting: true, fileManager: fm)) {
            XCTAssertTrue($0 is POSIXError)
        }
    }

    func testUISubdirectoryFailureNeverReturnsPartialOrOrdinaryRoots() {
        for call in [1, 2] {
            let fm = RefusingDirectoryCreation(failOnCall: call)
            defer {
                if let documents = fm.firstDirectory {
                    removeCreatedSandbox(.init(documents: documents, support: documents, isIsolated: true))
                }
            }
            XCTAssertThrowsError(try AppStorage.resolveRoots(
                environment: ["RAWFORGE_UI_TESTING": "1"], isXCTest: false,
                supportsUITesting: true, fileManager: fm)) {
                XCTAssertEqual(($0 as NSError).code, NSFileWriteNoPermissionError)
            }
            XCTAssertEqual(fm.calls, call)
            XCTAssertEqual(fm.ordinaryRootLookups, 0)
        }
    }

    #if !DEBUG || !targetEnvironment(simulator)
    func testCompiledUnsupportedBuildRejectsUIFlagByDefault() {
        let fm = RefusingDirectoryCreation(failOnCall: 1)
        XCTAssertThrowsError(try AppStorage.resolveRoots(
            environment: ["RAWFORGE_UI_TESTING": "1"], isXCTest: false, fileManager: fm))
        XCTAssertEqual(fm.calls, 0)
        XCTAssertEqual(fm.ordinaryRootLookups, 0)
    }
    #endif

    func testVerifiedXCTestWithoutExactOptInFailsClosed() {
        for environment in [[:], ["RAWFORGE_TEST_STORAGE": ""],
                            ["RAWFORGE_TEST_STORAGE": "0"],
                            ["RAWFORGE_TEST_STORAGE": "true"],
                            ["RAWFORGE_TEST_STORAGE": "/tmp/arbitrary-user-path"]] {
            XCTAssertThrowsError(try AppStorage.resolveRoots(environment: environment, isXCTest: true)) {
                guard case AppStorage.IsolationError.missingTestOptIn = $0 else {
                    return XCTFail("Expected missing opt-in, got \($0)")
                }
            }
        }
    }

    func testFlagAloneCannotEnableIsolationOutsideXCTest() {
        XCTAssertThrowsError(try AppStorage.resolveRoots(environment: optIn, isXCTest: false)) {
            guard case AppStorage.IsolationError.unverifiedTestLaunch = $0 else {
                return XCTFail("Expected unverified launch, got \($0)")
            }
        }
    }

    func testRunnerMarkersWithoutLoadedXCTestNeverSelectLiveRoots() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath",
                    "XCTestBundleInjectPath", "XCTestSessionIdentifier"] {
            // Before XCTest loads (or with a spoofed path), refuse both with
            // and without opt-in. Marker paths are never used as storage roots.
            for flag in [[:], optIn] {
                var environment = flag
                environment[key] = "/not/a/real/test/bundle.xctest"
                XCTAssertThrowsError(try AppStorage.resolveRoots(environment: environment, isXCTest: false)) {
                    guard case AppStorage.IsolationError.unverifiedTestLaunch = $0 else {
                        return XCTFail("Expected unverified launch, got \($0)")
                    }
                }
            }
        }
    }

    func testSandboxFactoryCreatesFreshPrivateRootsAndIgnoresPathOverrides() throws {
        var environment = optIn
        environment["RAWFORGE_TEST_STORAGE_ROOT"] = "/must/not/be/used"
        let first = try AppStorage.resolveRoots(environment: environment, isXCTest: true)
        defer { removeCreatedSandbox(first) }
        let second = try AppStorage.resolveRoots(environment: environment, isXCTest: true)
        defer { removeCreatedSandbox(second) }
        XCTAssertNotEqual(first.documents, second.documents,
                          "Independent processes must never adopt a previous sandbox")
        for roots in [first, second] {
            XCTAssertTrue(roots.isIsolated)
            let sandbox = roots.documents.deletingLastPathComponent()
            XCTAssertEqual(sandbox.deletingLastPathComponent().resolvingSymlinksInPath(),
                           FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
            XCTAssertEqual(roots.support, sandbox.appendingPathComponent("Library/Application Support", isDirectory: true))
            let permissions = try FileManager.default.attributesOfItem(atPath: sandbox.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
            for directory in [roots.documents, roots.support] {
                let marker = directory.appendingPathComponent("test-marker")
                try Data("isolated".utf8).write(to: marker)
                XCTAssertEqual(try Data(contentsOf: marker), Data("isolated".utf8))
            }
        }
    }

    func testSandboxCreationFailureThrowsInsteadOfReturningLiveRoots() throws {
        let fm = InvalidTemporaryDirectory()
        try Data().write(to: fm.blocker)
        defer { try? FileManager.default.removeItem(at: fm.blocker) }
        XCTAssertThrowsError(try AppStorage.resolveRoots(environment: optIn, isXCTest: true, fileManager: fm)) {
            XCTAssertTrue($0 is POSIXError)
        }
    }

    func testEitherSubdirectoryCreationFailureThrowsInsteadOfReturningPartialOrLiveRoots() {
        for call in [1, 2] {
            let fm = RefusingDirectoryCreation(failOnCall: call)
            defer {
                if let documents = fm.firstDirectory {
                    removeCreatedSandbox(.init(documents: documents, support: documents, isIsolated: true))
                }
            }
            XCTAssertThrowsError(try AppStorage.resolveRoots(environment: optIn, isXCTest: true, fileManager: fm)) {
                XCTAssertEqual(($0 as NSError).code, NSFileWriteNoPermissionError)
            }
            XCTAssertEqual(fm.calls, call)
        }
    }

    /// Only freshly created test fixtures; never process roots or live files.
    private func removeCreatedSandbox(_ roots: AppStorage.Roots) {
        let sandbox = roots.documents.deletingLastPathComponent()
        guard roots.isIsolated,
              sandbox.lastPathComponent.hasPrefix("RAWForge-XCTest-"),
              sandbox.deletingLastPathComponent().resolvingSymlinksInPath()
                == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
            return XCTFail("Refusing cleanup outside a generated test fixture")
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    private final class InvalidTemporaryDirectory: FileManager, @unchecked Sendable {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        override var temporaryDirectory: URL { blocker }
    }

    private final class RefusingDirectoryCreation: FileManager, @unchecked Sendable {
        let failOnCall: Int
        var calls = 0
        var firstDirectory: URL?
        var ordinaryRootLookups = 0

        init(failOnCall: Int) { self.failOnCall = failOnCall; super.init() }

        override func urls(for directory: FileManager.SearchPathDirectory,
                           in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            ordinaryRootLookups += 1
            return super.urls(for: directory, in: domainMask)
        }

        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            calls += 1
            if firstDirectory == nil { firstDirectory = url }
            if calls == failOnCall {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
    }
}
