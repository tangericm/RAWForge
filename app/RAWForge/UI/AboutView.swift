import SwiftUI

struct AboutView: View {
    let identity: DeviceIdentity

    var body: some View {
        List {
            Section("RAWForge") {
                LabeledContent("Version", value: identity.appVersion)
                LabeledContent("Build", value: identity.appBuild)
                LabeledContent("Commit") {
                    Text(commit).monospaced().font(.caption)
                }
                if identity.isDirtyBuild {
                    Label("This build contains uncommitted changes.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("This iPhone") {
                LabeledContent("Device identifier", value: identity.modelIdentifier)
                LabeledContent("iOS", value: identity.systemVersion)
                if identity.isSimulator {
                    Label("Simulator", systemImage: "cpu")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Open source") {
                LabeledContent("License", value: CompliancePresentation.licenseLabel)
                Text("RAWForge is released under the Apache License, Version 2.0.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link(destination: CompliancePresentation.sourceURL) {
                    Label("View Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
        .navigationTitle("Open Source & About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var commit: String {
        guard let commit = identity.appCommit, commit != "unknown" else {
            return "Not stamped"
        }
        return commit
    }
}
