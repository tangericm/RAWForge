import SwiftUI

@main
struct RAWForgeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First thing, before any capture code can fail: the log has to be open
        // to record the failure that opens it.
        DebugLog.shared.start(device: DeviceIdentity.current())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Dark throughout, not just on the capture screen. This is used
                // in the field, often in the dark, and a viewfinder next to a
                // white settings list ruins night vision and looks like two
                // different apps.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Backgrounding mid-station is a real field event — a call, a
                // lock button — and the capture session goes down with it.
                logWarn(.app, "app backgrounded")
                DebugLog.shared.noteCleanExit()
            case .active:
                logInfo(.app, "app active · \(DeviceHealth.snapshotSummary())")
            case .inactive:
                DebugLog.shared.flush()
            @unknown default:
                break
            }
        }
    }
}
