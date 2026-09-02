import SwiftUI

struct PrivacyDataView: View {
    private let bundledPolicy: String

    init() {
        bundledPolicy = Bundle.main.url(
            forResource: "privacy-policy",
            withExtension: "md"
        ).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ??
            "The bundled privacy policy could not be opened."
    }

    var body: some View {
        List {
            Section {
                Label(CompliancePresentation.dataCollectionLabel,
                      systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(CompliancePresentation.privacySummary)
                Text("RAWForge has no account, backend, analytics, advertising, tracking, third-party SDKs, Photos access, or automatic network transmission.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("On-device by design")
            }

            Section("Permissions") {
                permission(
                    "Camera",
                    systemImage: "camera",
                    description: CompliancePresentation.cameraPermissionDescription
                )
                permission(
                    "Motion",
                    systemImage: "gyroscope",
                    description: CompliancePresentation.motionPermissionDescription
                        + " Motion is optional; capture can continue without motion evidence."
                )
            }

            Section("Storage & backup") {
                Text("DNG frames, capture records, motion evidence, Recipes, and bounded diagnostic logs are stored locally in RAWForge’s app container.")
                Text("Capture folders are excluded from iCloud backup. Small operational files in Application Support remain subject to normal iOS backup behavior.")
            }

            Section("Export") {
                Text("RAWForge does not transmit data automatically. Data leaves only when you start an export or share action, use Files, or connect a cable and choose a destination.")
            }

            Section("Deletion") {
                Text("Deleting a capture removes its local DNG files and records. Deleting RAWForge removes data left in its app container. Copies you previously exported must be deleted at their destination.")
            }

            Section {
                Link(destination: CompliancePresentation.policyURL) {
                    Label("View Hosted Privacy Policy", systemImage: "safari")
                        .frame(minHeight: 44, alignment: .leading)
                }
                Text(renderedPolicy)
                    .font(.callout)
                    .textSelection(.enabled)
            } header: {
                Text("Bundled privacy policy")
            } footer: {
                Text("This copy is included with the app and remains available offline.")
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var renderedPolicy: AttributedString {
        (try? AttributedString(markdown: bundledPolicy)) ?? AttributedString(bundledPolicy)
    }

    private func permission(
        _ title: String,
        systemImage: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(description).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
