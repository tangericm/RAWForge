import SwiftUI
import UIKit

/// Release copy and public locations shared by Help & Settings and its tests.
/// Keeping this out of `CaptureModel` makes the surface reusable when the
/// current tabs become Shoot and Library.
struct CompliancePresentation {
    static let privacySummary =
        "Captures and diagnostics stay on this iPhone until you choose to export them."
    static let sourceURL = URL(string: "https://github.com/tangericm/RAWForge")!
    static let policyURL = URL(string: "https://tangericm.github.io/RAWForge/privacy/")!
    static let documentationURL = URL(
        string: "https://github.com/tangericm/RAWForge#readme"
    )!
    static let issuesURL = URL(string: "https://github.com/tangericm/RAWForge/issues")!

    static let cameraPermissionDescription =
        "RAWForge uses the camera to preview your scene and save the RAW captures you choose to make."
    static let motionPermissionDescription =
        "RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held."

    static let dataCollectionLabel = "Data Not Collected"
    static let licenseLabel = "Apache-2.0"

    static func buildDescription(for identity: DeviceIdentity) -> String {
        identity.buildDescription
    }
}

struct HelpSettingsView: View {
    let report: CapabilityReport?
    private let model: CaptureModel?
    private let identity: DeviceIdentity

    /// The presentation-only interface used by previews and future roots.
    init(report: CapabilityReport?) {
        self.report = report
        model = nil
        identity = report?.device ?? .current()
    }

    /// The live app supplies its existing composition root so device
    /// measurement uses the same rig without replacing capture state.
    init(report: CapabilityReport?, model: CaptureModel) {
        self.report = report
        self.model = model
        identity = report?.device ?? .current()
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PrivacyDataView()
                } label: {
                    destination("Privacy & Data", systemImage: "hand.raised")
                }

                NavigationLink {
                    ThisIPhoneView(report: report, model: model)
                } label: {
                    destination("This iPhone", systemImage: "iphone")
                }

                NavigationLink {
                    DiagnosticsView(identity: identity)
                } label: {
                    destination("Diagnostics", systemImage: "stethoscope")
                }

                NavigationLink {
                    SupportView(identity: identity)
                } label: {
                    destination("Support", systemImage: "questionmark.circle")
                }

                NavigationLink {
                    AboutView(identity: identity)
                } label: {
                    destination("Open Source & About", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Help & Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func destination(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(minHeight: 44, alignment: .leading)
    }
}

private struct ThisIPhoneView: View {
    let report: CapabilityReport?
    let model: CaptureModel?

    var body: some View {
        Group {
            if let report {
                List {
                    CapabilitySummarySection(report: report)

                    Section("Sensors") {
                        ForEach(report.sensors) { sensor in
                            SensorSummaryRow(sensor: sensor)
                        }
                    }

                    Section("Device profile") {
                        if let model {
                            NavigationLink {
                                DeviceProfileView(model: model)
                            } label: {
                                profileRow
                            }
                        } else {
                            profileRow
                        }
                    }

                    Section("Storage & calibration") {
                        if let free = SessionStore.availableCapacityBytes() {
                            LabeledContent(
                                "Available storage",
                                value: SessionEstimate.formatBytes(free)
                            )
                        }
                        LabeledContent("Calibration", value: calibrationStatus)
                    }

                    Section("Device") {
                        LabeledContent("Identifier", value: report.device.modelIdentifier)
                        LabeledContent(
                            "iOS",
                            value: report.device.systemVersion
                        )
                        LabeledContent(
                            "Burst ceiling",
                            value: "\(report.sharedBracketCeiling) frames"
                        )
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Device details unavailable", systemImage: "iphone.slash")
                } description: {
                    Text("RAWForge has not finished checking this iPhone yet.")
                }
            }
        }
        .navigationTitle("This iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var profileRow: some View {
        let profile = DeviceProfile.active
        return VStack(alignment: .leading, spacing: 3) {
            Text(profile.isCharacterised ? "Measured on this iPhone" : "Reference estimates")
            Text(profile.isCharacterised
                 ? "\(profile.borrowedCount) of \(profile.readings.count) values still borrowed"
                 : "Timing values are borrowed from \(DeviceProfile.referenceDevice)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    private var calibrationStatus: String {
        guard let calibration = SessionStore.latestCalibration() else {
            return "Not measured"
        }
        let hours = Int(calibration.ageSeconds / 3_600)
        return hours < 1 ? "Measured within the last hour" : "Measured \(hours) hours ago"
    }
}

private struct DiagnosticsView: View {
    let identity: DeviceIdentity
    @State private var shared: ExportedArchive?
    @State private var warningCount = 0
    @State private var errorCount = 0
    @State private var eventCount = 0

    var body: some View {
        List {
            Section("Current health") {
                LabeledContent("Errors", value: "\(errorCount)")
                LabeledContent("Warnings", value: "\(warningCount)")
                LabeledContent("Recorded events", value: "\(eventCount)")
            }

            Section {
                NavigationLink {
                    LogConsoleView()
                } label: {
                    Label("Recent activity & earlier reports", systemImage: "list.bullet.rectangle")
                        .frame(minHeight: 44, alignment: .leading)
                }

                Button {
                    shareCurrentReport()
                } label: {
                    Label("Share Diagnostic Report", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(DebugLog.shared.fileURL == nil)
            } header: {
                Text("Reports")
            } footer: {
                Text("Reports stay on this iPhone unless you choose to share one. They contain no RAW image data or analytics identifier.")
            }

            Section("Build") {
                LabeledContent(
                    "Build ID",
                    value: CompliancePresentation.buildDescription(for: identity)
                )
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
        .onAppear { refreshTally() }
    }

    private func refreshTally() {
        let tally = DebugLog.shared.tally()
        warningCount = tally.warnings
        errorCount = tally.errors
        eventCount = tally.total
    }

    private func shareCurrentReport() {
        DebugLog.shared.flush()
        if let url = DebugLog.shared.fileURL {
            shared = ExportedArchive(url: url)
        }
    }
}

private struct SupportView: View {
    let identity: DeviceIdentity
    @State private var copied = false

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Build ID",
                    value: CompliancePresentation.buildDescription(for: identity)
                )
                Button {
                    copyBuildID()
                } label: {
                    Label(copied ? "Build ID Copied" : "Copy Build ID",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minHeight: 44, alignment: .leading)
                }
            } header: {
                Text("When asking for help")
            } footer: {
                Text("Include the Build ID and, when relevant, a diagnostic report so a problem can be tied to the code that produced it.")
            }

            Section("Links") {
                Link(destination: CompliancePresentation.documentationURL) {
                    Label("Documentation", systemImage: "book")
                        .frame(minHeight: 44, alignment: .leading)
                }
                Link(destination: CompliancePresentation.issuesURL) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                        .frame(minHeight: 44, alignment: .leading)
                }
                Link(destination: CompliancePresentation.sourceURL) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyBuildID() {
        UIPasteboard.general.string = CompliancePresentation.buildDescription(for: identity)
        copied = true
        UIAccessibility.post(notification: .announcement, argument: "Build ID copied")
    }
}
