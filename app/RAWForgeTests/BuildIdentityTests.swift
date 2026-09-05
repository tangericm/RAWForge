import XCTest
@testable import RAWForge

/// Identifying which build produced a log.
///
/// This exists because of a concrete failure: during device testing every build
/// reported `1.0 (1)`, so two logs from different builds were indistinguishable
/// and there was no way to tell which code had produced a symptom.
final class BuildIdentityTests: XCTestCase {

    private func identity(version: String = "1.0", build: String = "2608141711",
                          commit: String?) -> DeviceIdentity {
        DeviceIdentity(modelIdentifier: "iPhone16,1", systemName: "iOS",
                       systemVersion: "26.0", appVersion: version, appBuild: build,
                       appCommit: commit, isSimulator: false)
    }

    func testABuildDescribesItselfWithVersionNumberAndCommit() {
        XCTAssertEqual(identity(commit: "67ea37f").buildDescription, "1.0 (2608141711) 67ea37f")
    }

    /// The placeholder in the source Info.plist. If the stamping build phase
    /// did not run, the description must not claim a commit it does not have.
    func testAnUnstampedBuildOmitsTheCommitRatherThanClaimingOne() {
        XCTAssertEqual(identity(commit: "unknown").buildDescription, "1.0 (2608141711)")
        XCTAssertEqual(identity(commit: nil).buildDescription, "1.0 (2608141711)")
    }

    /// A dirty build corresponds to no commit anyone else can check out, which
    /// is worth knowing before chasing a bug through code that was never what
    /// actually ran.
    func testADirtyTreeIsCarriedThroughAndFlagged() {
        let dirty = identity(commit: "52c3ac5-dirty")
        XCTAssertTrue(dirty.isDirtyBuild)
        XCTAssertEqual(dirty.buildDescription, "1.0 (2608141711) 52c3ac5-dirty")

        XCTAssertFalse(identity(commit: "52c3ac5").isDirtyBuild)
        XCTAssertFalse(identity(commit: "unknown").isDirtyBuild)
        XCTAssertFalse(identity(commit: nil).isDirtyBuild)
    }

    /// The build number is a UTC date-time stamp, so it can never collide or go
    /// backwards — which is what App Store Connect requires within a version.
    func testTheRunningBuildCarriesADateStampedNumberAndACommit() throws {
        let here = DeviceIdentity.current()

        let build = here.appBuild
        XCTAssertNotEqual(build, "1", "the build-stamping phase must run after plist generation")
        XCTAssertEqual(build.count, 10, "expected YYMMDDHHmm, got \(build)")
        XCTAssertNotNil(Int(build), "the build number must be numeric to sort correctly")

        let commit = try XCTUnwrap(here.appCommit)
        XCTAssertNotEqual(commit, "unknown",
                          "the stamping phase ran, so it should have found a commit")
    }

    /// Declared in the manifest because the code calls it, and nothing else is.
    /// An over-broad manifest invites questions it cannot answer.
    func testThePrivacyManifestDeclaresExactlyTheAPIsTheCodeUses() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "the privacy manifest is not in the bundle — an upload rejection")
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any])

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0,
                       "the app collects nothing, and the manifest must say so")

        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = Dictionary(uniqueKeysWithValues: apis.map {
            ($0["NSPrivacyAccessedAPIType"] as! String,
             $0["NSPrivacyAccessedAPITypeReasons"] as! [String])
        })
        XCTAssertEqual(declared, [
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
        ])
    }

    func testTheBuiltAppUsesTheApprovedPermissionDescriptions() {
        XCTAssertEqual(
            Bundle.main.infoDictionary?["NSCameraUsageDescription"] as? String,
            "RAWForge uses the camera to preview your scene and save the RAW captures you choose to make."
        )
        XCTAssertEqual(
            Bundle.main.infoDictionary?["NSMotionUsageDescription"] as? String,
            "RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held."
        )
    }

    func testThePrivacyPolicyIsBundledWithTheApp() throws {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "privacy-policy", withExtension: "md"),
            "privacy-policy.md must be available offline from Privacy & Data"
        )
    }

    func testTheBundledAppStoreAndHostedPrivacyPoliciesAreByteIdentical() throws {
        let bundled = try XCTUnwrap(
            Bundle.main.url(forResource: "privacy-policy", withExtension: "md")
        )
        let testBundle = Bundle(for: BuildIdentityTests.self)
        let appStore = try XCTUnwrap(
            testBundle.url(forResource: "privacy-policy", withExtension: "md")
        )
        let hosted = try XCTUnwrap(
            testBundle.url(forResource: "index", withExtension: "md")
        )

        let expected = try Data(contentsOf: bundled)
        XCTAssertEqual(try Data(contentsOf: appStore), expected)
        XCTAssertEqual(try Data(contentsOf: hosted), expected)
    }

    func testDynamicTypeAuditSourcesExistOnlyInTheTestBundle() throws {
        let testBundle = Bundle(for: BuildIdentityTests.self)

        for resource in ["DeviceProfileView", "LogConsoleView"] {
            XCTAssertNotNil(
                testBundle.url(forResource: resource, withExtension: "swift.txt"),
                "\(resource).swift must remain available to the simulator regression gate"
            )
            XCTAssertNil(
                Bundle.main.url(forResource: resource, withExtension: "swift.txt"),
                "test audit sources must not ship in the app bundle"
            )
        }
    }

    /// Without this, every submission stops to ask the same question.
    func testExportComplianceIsDeclaredSoSubmissionDoesNotStopToAsk() {
        XCTAssertEqual(Bundle.main.infoDictionary?["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }
}
