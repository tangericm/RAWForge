import Combine
import Foundation
import UIKit

/// Thermal and battery monitoring.
///
/// #10 lists both as hard faults that abort the station and delete its frames,
/// alongside storage exhausted and capture error. Neither was being watched, so
/// the app would have kept shooting into a thermal shutdown or a dying battery
/// and lost the station to a crash instead of to a rule.
///
/// The distinction matters: a fault aborts cleanly and says why, and stations
/// already banked survive. A crash takes whatever was in flight and leaves
/// orphans behind for the launch sweep to find.
@MainActor
final class DeviceHealth: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown

    private var cancellables: Set<AnyCancellable> = []

    /// Below this the instrument may not survive a long station. 10% on a phone
    /// that has been capturing is optimistic rather than conservative — RAW
    /// capture and sustained writes drain fast.
    static let batteryFaultLevel: Float = 0.10
    static let batteryWarnLevel: Float = 0.20

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func refresh() {
        let previous = thermalState
        thermalState = ProcessInfo.processInfo.thermalState
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        // A thermal transition explains a run that suddenly takes half again as
        // long, and it is invisible in every other record.
        if previous != thermalState {
            let rising = thermalState.rawValue > previous.rawValue
            DebugLog.shared.write(rising && thermalFault ? .error : rising ? .warn : .info,
                                  .app, "thermal state \(label(previous)) → \(thermalLabel)")
        }
    }

    private func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Readable from anywhere, including the scene-phase handler, without
    /// hopping to the main actor just to write one log line.
    nonisolated static func snapshotSummary() -> String {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let free = SessionStore.availableCapacityBytes()
            .map { "\(SessionEstimate.formatBytes($0)) free" } ?? "capacity unreadable"
        return "thermal \(thermal) · \(free)"
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// `.critical` only. `.serious` is the system throttling, which slows a run
    /// without invalidating it — aborting there would destroy good stations for
    /// a condition the operator can simply wait out.
    var thermalFault: Bool { thermalState == .critical }
    var thermalWarning: Bool { thermalState == .serious }

    var batteryFault: Bool {
        batteryState != .charging && batteryState != .full
            && batteryLevel >= 0 && batteryLevel < Self.batteryFaultLevel
    }
    var batteryWarning: Bool {
        batteryState != .charging && batteryState != .full
            && batteryLevel >= 0 && batteryLevel < Self.batteryWarnLevel
    }

    /// Checked before a station starts and before each set, so a fault lands at
    /// a boundary rather than halfway through a bracket.
    func faultIfUnhealthy() -> StationFault? {
        if thermalFault { return .thermal }
        if batteryFault { return .batteryDeath }
        return nil
    }

    var summary: String {
        let b = batteryLevel < 0 ? "battery unknown"
            : String(format: "battery %.0f%%%@", batteryLevel * 100,
                     batteryState == .charging || batteryState == .full ? " (charging)" : "")
        return "thermal \(thermalLabel) · \(b)"
    }
}
