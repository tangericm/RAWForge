import XCTest
@testable import RAWForge

final class CompliancePresentationTests: XCTestCase {

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
        let identity = DeviceIdentity(
            modelIdentifier: "iPhone16,1",
            systemName: "iOS",
            systemVersion: "26.0",
            appVersion: "1.0",
            appBuild: "2609011700",
            appCommit: "81a7bcb",
            isSimulator: false
        )

        XCTAssertEqual(
            CompliancePresentation.buildDescription(for: identity),
            "1.0 (2609011700) 81a7bcb"
        )
    }
}
