import SwiftUI

@main
struct RAWForgeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var launchNotice: LaunchNoticeStore

    init() {
        // Before anything reads the shot list or the profile: an install that
        // predates the split still has them in Documents.
        AppStorage.migrateAll()

        // Legacy records reject the current decoders, and old logs contain
        // unstructured uptime. Resolve both before a store or log reads them.
        let markerURL = AppStorage.supportFile("privacy-migration-v1.json")
        let maintenance = LaunchStorageMaintenance.run(
            sessionsRoot: SessionStore.sessionsRoot,
            logsRoot: DebugLog.directory,
            markerURL: markerURL)
        let migration = maintenance.migration
        _launchNotice = StateObject(
            wrappedValue: LaunchNoticeStore(
                markerURL: markerURL,
                orphanedFramesRemoved: maintenance.orphanedFramesRemoved))

        DebugLog.shared.start(device: DeviceIdentity.current())
        ProtocolLibrary.ensureDirectory()
        if migration.migratedSessions > 0 || migration.removedLogs > 0 {
            logInfo(.store, "privacy migration updated \(migration.migratedSessions) session(s) "
                    + "and cleared \(migration.removedLogs) legacy log(s)")
        }
        if migration.untouchedUnknownRecords > 0 {
            logWarn(.store, "privacy migration left \(migration.untouchedUnknownRecords) "
                    + "unknown record(s) untouched")
        }
        for failure in migration.failures {
            logError(.store, "privacy migration failed — \(failure)")
        }
        if maintenance.orphanedFramesRemoved > 0 {
            logWarn(
                .store,
                "swept \(maintenance.orphanedFramesRemoved) orphaned frame(s) "
                    + "from a valid current session with no owning station metadata")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(launchNoticeStore: launchNotice)
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
