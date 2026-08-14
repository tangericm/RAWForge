import SwiftUI
import UIKit

/// A share sheet for an exported session archive.
///
/// Wrapped rather than using `ShareLink` because the archive has to be built
/// first — a session is a folder of DNGs and zipping 2 GB is not something to
/// do speculatively when a view renders.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so a URL can drive `.sheet(item:)`.
struct ExportedArchive: Identifiable {
    let id = UUID()
    let url: URL
}
