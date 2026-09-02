import XCTest
@testable import RAWForge

final class CompliancePresentationTests: XCTestCase {

    func testCameraDeniedRootExposesHelpSettingsAndRequiredDestinations() throws {
        let state = ContentRootState.resolve(
            cameraDenied: true,
            bootState: .ready)

        XCTAssertEqual(state, .cameraDenied)
        try assertHelpSettingsReachable(
            from: state,
            expectedActions: ["Open Settings", "Help & Settings"])
    }

    func testBootFailureRootExposesHelpSettingsAndRequiredDestinations() throws {
        let state = ContentRootState.resolve(
            cameraDenied: false,
            bootState: .failed("sensor probe did not return a report"))

        XCTAssertEqual(state, .bootFailed("sensor probe did not return a report"))
        try assertHelpSettingsReachable(
            from: state,
            expectedActions: ["Help & Settings"])
    }

    func testBundledPrivacyPolicyLoaderReadsThePolicyShownByPrivacyData() throws {
        let policy = try BundledPrivacyPolicy.load()

        XCTAssertTrue(policy.hasPrefix("# RAWForge Privacy Policy"))
        XCTAssertTrue(policy.contains("RAWForge also marks the diagnostics directory"))
    }

    func testHelpSettingsFactoryConstructsEveryRequiredDestinationInOrder() {
        let expected: [HelpSettingsDestination] = [
            .privacyData, .thisIPhone, .diagnostics, .support, .openSourceAbout
        ]
        let factory = HelpSettingsDestinationFactory(
            report: nil,
            model: nil,
            identity: deviceIdentity()
        )

        XCTAssertEqual(HelpSettingsDestination.allCases, expected)
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
        XCTAssertEqual(
            HelpSettingsDestination.allCases.map { factory.view(for: $0).kind },
            expected,
            "HelpSettingsView and this test must use the same destination factory"
        )
        XCTAssertEqual(
            HelpSettingsDestination.allCases.map {
                ObjectIdentifier(factory.view(for: $0).contentType)
            },
            [
                ObjectIdentifier(PrivacyDataView.self),
                ObjectIdentifier(ThisIPhoneView.self),
                ObjectIdentifier(DiagnosticsView.self),
                ObjectIdentifier(SupportView.self),
                ObjectIdentifier(AboutView.self)
            ],
            "each Help & Settings route must construct its intended concrete view"
        )
    }

    func testReusedSettingsDestinationsRejectFixedPointFonts() throws {
        let testBundle = Bundle(for: CompliancePresentationTests.self)
        let fixedPointFont = #"\.font\s*\(\s*\.system\s*\(\s*size\s*:"#

        for resource in ["DeviceProfileView", "LogConsoleView"] {
            let url = try XCTUnwrap(
                testBundle.url(forResource: resource, withExtension: "swift.txt"),
                "\(resource).swift must be a test-only resource for the Dynamic Type gate"
            )
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(
                source.range(of: fixedPointFont, options: .regularExpression),
                "\(resource).swift must use semantic or scaled fonts"
            )
        }
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

    private func assertHelpSettingsReachable(
        from state: ContentRootState,
        expectedActions: [String]
    ) throws {
        let presentation = try XCTUnwrap(state.unavailablePresentation)
        XCTAssertEqual(presentation.actions.map(\.title), expectedActions)
        XCTAssertTrue(presentation.actions.contains(.helpSettings))
        XCTAssertTrue(presentation.helpSettingsDestinations.contains(.privacyData))
        XCTAssertTrue(presentation.helpSettingsDestinations.contains(.support))

        let factory = HelpSettingsDestinationFactory(
            report: nil,
            model: nil,
            identity: deviceIdentity())
        XCTAssertEqual(
            ObjectIdentifier(factory.view(for: .privacyData).contentType),
            ObjectIdentifier(PrivacyDataView.self))
        XCTAssertEqual(
            ObjectIdentifier(factory.view(for: .support).contentType),
            ObjectIdentifier(SupportView.self))
    }
}
