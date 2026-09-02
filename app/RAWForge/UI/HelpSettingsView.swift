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

enum HelpSettingsDestination: String, CaseIterable, Identifiable {
    case privacyData
    case thisIPhone
    case diagnostics
    case support
    case openSourceAbout

    var id: Self { self }

    var title: String {
        switch self {
        case .privacyData: return "Privacy & Data"
        case .thisIPhone: return "This iPhone"
        case .diagnostics: return "Diagnostics"
        case .support: return "Support"
        case .openSourceAbout: return "Open Source & About"
        }
    }

    var systemImage: String {
        switch self {
        case .privacyData: return "hand.raised"
        case .thisIPhone: return "iphone"
        case .diagnostics: return "stethoscope"
        case .support: return "questionmark.circle"
        case .openSourceAbout: return "info.circle"
        }
    }
}

struct BuildIDClipboard {
    private let write: (String) -> Void

    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    static let system = BuildIDClipboard { UIPasteboard.general.string = $0 }

    func copyBuildID(for identity: DeviceIdentity) {
        write(CompliancePresentation.buildDescription(for: identity))
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
                ForEach(HelpSettingsDestination.allCases) { route in
                    NavigationLink {
                        view(for: route)
                    } label: {
                        destinationLabel(route)
                    }
                }
            }
        }
        .navigationTitle("Help & Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func destinationLabel(_ route: HelpSettingsDestination) -> some View {
        Label(route.title, systemImage: route.systemImage)
            .frame(minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private func view(for route: HelpSettingsDestination) -> some View {
        switch route {
        case .privacyData:
            PrivacyDataView()
        case .thisIPhone:
            ThisIPhoneView(report: report, model: model)
        case .diagnostics:
            DiagnosticsView(identity: identity)
        case .support:
            SupportView(identity: identity)
        case .openSourceAbout:
            AboutView(identity: identity)
        }
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
                .disabled(DebugLog.shared.currentReportURL() == nil)
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
        if let url = DebugLog.shared.currentReportURL() {
            shared = ExportedArchive(url: url)
        }
    }
}

private struct SupportView: View {
    let identity: DeviceIdentity
    let clipboard: BuildIDClipboard
    @State private var copied = false

    init(identity: DeviceIdentity, clipboard: BuildIDClipboard = .system) {
        self.identity = identity
        self.clipboard = clipboard
    }

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
        clipboard.copyBuildID(for: identity)
        copied = true
        UIAccessibility.post(notification: .announcement, argument: "Build ID copied")
    }
}
