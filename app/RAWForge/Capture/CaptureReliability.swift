import AVFoundation
import Foundation

/// Pure policy around the camera-service failure modes. Keeping the decision
/// here makes the dangerous part — whether to fire again — testable without a
/// camera or a simulated AVFoundation callback.
enum CaptureReliability {
    static let timeoutFloor: TimeInterval = 15
    static let processingMargin: TimeInterval = 10
    static let resourcePreparationTimeout: TimeInterval = 15

    /// A stuck XPC request otherwise has no deadline at all. The floor covers
    /// normal RAW processing; summed exposure time keeps a legitimate long
    /// bracket from being mistaken for a hung service.
    nonisolated static func requestTimeout(exposureSeconds: [Double]) -> TimeInterval {
        max(timeoutFloor, exposureSeconds.reduce(0) { $0 + max(0, $1) } + processingMargin)
    }

    nonisolated static func sessionUnavailable(isRunning: Bool,
                                               isInterrupted: Bool) -> Bool {
        !isRunning || isInterrupted
    }

    /// Characterisation writes no data, so it may rebuild and repeat once.
    /// Normal stations deliberately do not use this: repeating an unknown
    /// subset of a scientific capture would be worse than aborting it.
    nonisolated static func shouldRecoverBench(after error: Error,
                                               recoveryCount: Int) -> Bool {
        guard recoveryCount == 0 else { return false }
        if let rig = error as? CaptureRig.RigError {
            switch rig {
            case .captureFailed, .captureTimedOut:
                return true
            case .noDevice, .noBayerFormat, .notConfigured, .unsupported:
                return false
            }
        }
        return CaptureSessionDiagnostics.errorChain(error).contains {
            $0.domain == AVFoundationErrorDomain
        }
    }
}

/// Delivers the first result from competing asynchronous completions and drops
/// every later one. AVFoundation may call back after RAWForge's own deadline;
/// checked continuations turn that ordinary race into a process crash unless
/// the winner is chosen under a lock.
final class LockedResultGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: ((Result<Value, Error>) -> Void)?

    init(deliver: @escaping (Result<Value, Error>) -> Void) {
        self.deliver = deliver
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        let callback = deliver
        deliver = nil
        lock.unlock()
        callback?(result)
    }
}

/// Converts AVFoundation notifications and nested `NSError`s into flight-log
/// text. `localizedDescription` alone hid the useful evidence in #33: the
/// public error was `-11803`, while the invalid XPC channel was two layers
/// underneath it.
enum CaptureSessionDiagnostics {
    nonisolated static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let current = next, chain.count < 8 {
            let identity = ObjectIdentifier(current)
            guard seen.insert(identity).inserted else { break }
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    nonisolated static func describe(error: Error) -> String {
        errorChain(error).map {
            "\($0.domain)/\($0.code) \($0.localizedDescription)"
        }.joined(separator: " <- ")
    }

    nonisolated static func interruptionReasonName(_ rawValue: Int) -> String {
        switch AVCaptureSession.InterruptionReason(rawValue: rawValue) {
        case .videoDeviceNotAvailableInBackground:
            return "video unavailable in background"
        case .audioDeviceInUseByAnotherClient:
            return "audio in use by another client"
        case .videoDeviceInUseByAnotherClient:
            return "video in use by another client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "video unavailable with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "video unavailable due to system pressure"
        case .sensitiveContentMitigationActivated:
            return "sensitive-content mitigation activated"
        case .none:
            return "unknown(\(rawValue))"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }

    static func pressureSummary(_ device: AVCaptureDevice?) -> String {
        guard let state = device?.systemPressureState else { return "pressure unavailable" }
        let level: String
        switch state.level {
        case .nominal:  level = "nominal"
        case .fair:     level = "fair"
        case .serious:  level = "serious"
        case .critical: level = "critical"
        case .shutdown: level = "shutdown"
        default: level = "unknown"
        }
        return "pressure \(level) factors=\(state.factors.rawValue)"
    }
}
