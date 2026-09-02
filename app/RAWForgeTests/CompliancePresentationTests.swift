import XCTest
@testable import RAWForge

final class CompliancePresentationTests: XCTestCase {

    func testBundledPrivacyPolicyLoaderReadsThePolicyShownByPrivacyData() throws {
        let policy = try BundledPrivacyPolicy.load()

        XCTAssertTrue(policy.hasPrefix("# RAWForge Privacy Policy"))
        XCTAssertTrue(policy.contains("RAWForge also marks the diagnostics directory"))
    }

    func testHelpSettingsDestinationModelBuildsEveryRequiredRouteInOrder() {
        XCTAssertEqual(
            HelpSettingsDestination.allCases,
            [.privacyData, .thisIPhone, .diagnostics, .support, .openSourceAbout]
        )
        XCTAssertEqual(
            HelpSettingsDestination.allCases.map(\.title),
            [
                "Privacy & Data",
                "This iPhone",
                "Diagnostics",
                "Support",
                "Open Source & About"
            ]
        )
    }

    func testBuildIDClipboardCopiesTheDisplayedBuildDescription() {
        let identity = deviceIdentity()
        var copiedText: String?
        let clipboard = BuildIDClipboard { copiedText = $0 }

        clipboard.copyBuildID(for: identity)

        XCTAssertEqual(copiedText, CompliancePresentation.buildDescription(for: identity))
    }

    func testPrivacySummaryAndPublishedLocationsMatchTheReleaseMetadata() {
        XCTAssertEqual(
            CompliancePresentation.privacySummary,
            "Captures and diagnostics stay on this iPhone until you choose to export them."
        )
        XCTAssertEqual(
            CompliancePresentation.sourceURL.absoluteString,
            "https://github.com/tangericm/RAWForge"
        )
        XCTAssertEqual(
            CompliancePresentation.policyURL.absoluteString,
            "https://tangericm.github.io/RAWForge/privacy/"
        )
    }

    func testPermissionDescriptionsMatchTheApprovedReleaseCopy() {
        XCTAssertEqual(
            CompliancePresentation.cameraPermissionDescription,
            "RAWForge uses the camera to preview your scene and save the RAW captures you choose to make."
        )
        XCTAssertEqual(
            CompliancePresentation.motionPermissionDescription,
            "RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held."
        )
    }

    func testPrivacyAndLicenseLabelsUseTheSubmissionWording() {
        XCTAssertEqual(CompliancePresentation.dataCollectionLabel, "Data Not Collected")
        XCTAssertEqual(CompliancePresentation.licenseLabel, "Apache-2.0")
    }

    func testBuildDescriptionUsesVersionBuildAndCommit() {
        XCTAssertEqual(
            CompliancePresentation.buildDescription(for: deviceIdentity()),
            "1.0 (2609011700) 81a7bcb"
        )
    }

    private func deviceIdentity() -> DeviceIdentity {
        DeviceIdentity(
            modelIdentifier: "iPhone16,1",
            systemName: "iOS",
            systemVersion: "26.0",
            appVersion: "1.0",
            appBuild: "2609011700",
            appCommit: "81a7bcb",
            isSimulator: false
        )
    }
}
