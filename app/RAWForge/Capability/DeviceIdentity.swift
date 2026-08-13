import Foundation
import UIKit

/// Device model, OS and app version — the session header's provenance line (#6).
///
/// `UIDevice.model` is useless here ("iPhone"); the calibration-relevant string
/// is the hardware identifier, `iPhone16,1`, which only `uname` surfaces.
struct DeviceIdentity: Codable, Equatable {
    let modelIdentifier: String
    let systemName: String
    let systemVersion: String
    let appVersion: String
    let appBuild: String

    /// True when the session was recorded under the simulator. A simulated
    /// session can never be a calibration source, and the header has to say so
    /// rather than let a reader assume otherwise.
    let isSimulator: Bool

    static func current() -> DeviceIdentity {
        let info = Bundle.main.infoDictionary
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return DeviceIdentity(
            modelIdentifier: simulated ?? hardwareIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            isSimulator: simulated != nil)
    }

    /// On real hardware this is `iPhone16,1`. Under the simulator `uname`
    /// reports the *host* architecture (`arm64`), which is why the environment
    /// is consulted first — a header claiming model "arm64" is worse than
    /// useless as provenance.
    private static func hardwareIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
