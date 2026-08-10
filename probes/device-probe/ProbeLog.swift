import Foundation
import Combine

/// The live transcript. Every probe appends here; the view renders it and the
/// operator copies it back onto #14. Kept trivially simple on purpose.
@MainActor
final class ProbeLog: ObservableObject {
    @Published private(set) var lines: [String] = []

    var text: String { lines.joined(separator: "\n") }

    func log(_ s: String) {
        lines.append(s)
        print(s)
    }

    /// A visible section break so a pasted run is readable.
    func section(_ title: String) {
        log("")
        log("========== \(title) ==========")
    }

    func clear() { lines.removeAll() }
}
