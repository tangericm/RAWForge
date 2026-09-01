import Foundation

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

    /// The commit the binary was built from, stamped at build time.
    ///
    /// The build number says *when*; this says *from what*. Without it a log
    /// cannot be tied back to source, which is exactly the problem the old
    /// hardcoded `1.0 (1)` caused during testing — every build reported the
    /// same thing. A `-dirty` suffix means the binary corresponds to no commit
    /// anyone else can check out, which is worth knowing before chasing a bug
    /// through code that was never what ran.
    let appCommit: String?

    /// `1.0 (2608141530) 67ea37f-dirty` — everything needed to identify a build.
    var buildDescription: String {
        let base = "\(appVersion) (\(appBuild))"
        guard let appCommit, appCommit != "unknown" else { return base }
        return "\(base) \(appCommit)"
    }

    /// True when the binary was built from a working tree with uncommitted
    /// changes, so it matches no commit in the history.
    var isDirtyBuild: Bool { appCommit?.hasSuffix("-dirty") ?? false }

    /// True when the session was recorded under the simulator. A simulated
    /// session can never be a calibration source, and the header has to say so
    /// rather than let a reader assume otherwise.
    let isSimulator: Bool

    static func current() -> DeviceIdentity {
        let info = Bundle.main.infoDictionary
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let patch = os.patchVersion == 0 ? "" : ".\(os.patchVersion)"
        return DeviceIdentity(
            modelIdentifier: simulated ?? hardwareIdentifier(),
            systemName: "iOS",
            systemVersion: "\(os.majorVersion).\(os.minorVersion)\(patch)",
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            appCommit: info?["RAWForgeCommit"] as? String,
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
