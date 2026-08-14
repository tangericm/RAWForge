import ImageIO
import SwiftUI
import UIKit

/// The log browser (#12), simplified by the pass that removed verdicts.
///
/// Its purpose is *"what did I shoot"*, not *"did station 3 actually complete"* —
/// a station either completed or never existed, so there is no completion
/// status to display and no opinion for the app to form.
///
/// Thumbnails are the DNG's own embedded preview, read and **never generated**.
/// That is the line #12 draws and does not move: the app may read tags and do
/// arithmetic on raw values, but it may not demosaic, apply colour, or apply
/// white balance to pixels. Rendering a preview from the Bayer payload would
/// cross it, and would put a tone-mapped image on screen while appearing to
/// show the data being kept.
struct SessionBrowser: View {
    @State private var sessions: [String] = []
    @State private var pendingDelete: String?
    @State private var deleteError: String?

    var body: some View {
        Group {
            if sessions.isEmpty { empty } else { list }
        }
        .navigationTitle("Sessions")
        .toolbar { if !sessions.isEmpty { EditButton() } }
        .onAppear { reload() }
        .confirmationDialog(
            "Delete this session permanently?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let id = pendingDelete {
                Button("Delete \(id) · \(SessionEstimate.formatBytes(SessionExport.sizeOnDisk(sessionId: id)))",
                       role: .destructive) { delete(id) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The frames and the log go together. There is no undo, and the app "
                 + "does not track whether this session was transferred.")
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "folder")
        } description: {
            Text("A session is opened from the Capture screen, and everything shot into it "
                 + "lands in one directory — the frames and the log together.")
        }
    }

    private var list: some View {
        List {
            if let e = deleteError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            Section {
                LabeledContent("On disk", value: SessionExport.formatTotal(sessions))
                if let free = SessionStore.availableCapacityBytes() {
                    LabeledContent("Free", value: SessionEstimate.formatBytes(free))
                }
            }
            ForEach(sessions, id: \.self) { id in
                NavigationLink(destination: SessionDetail(sessionId: id)) {
                    SessionRow(sessionId: id)
                }
            }
            .onDelete { offsets in
                pendingDelete = offsets.first.map { sessions[$0] }
            }
        }
    }

    private func reload() { sessions = SessionStore.existingSessionIds().reversed() }

    private func delete(_ id: String) {
        do { try SessionStore.deleteSession(id); deleteError = nil }
        catch { deleteError = "Could not delete \(id): \(error.localizedDescription)" }
        pendingDelete = nil
        reload()
    }
}

private struct SessionRow: View {
    let sessionId: String

    var body: some View {
        let counts = SessionStore.frameAndStationCount(sessionId: sessionId)
        VStack(alignment: .leading, spacing: 2) {
            Text(sessionId).font(.callout).monospaced()
            Text("\(counts.stations) station(s) · \(counts.frames) frame(s) · \(counts.megabytes) MB")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SessionDetail: View {
    let sessionId: String
    @State private var record: SessionRecord?
    @State private var stations: [StationRecord] = []
    @State private var unreadable: [String] = []
    @State private var archive: ExportedArchive?
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        List {
            if let e = exportError {
                Section { Text(e).font(.caption).foregroundStyle(.red) }
            }
            if !unreadable.isEmpty {
                Section("Unreadable records") {
                    ForEach(unreadable, id: \.self) { Text($0).font(.caption).monospaced() }
                    Text("These station files exist but did not parse. Their frames are still "
                         + "on disk; the log for them is not.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if let r = record {
                Section("Session") {
                    LabeledContent("Device", value: r.capability.device.modelIdentifier)
                    LabeledContent("OS", value: r.capability.device.systemVersion)
                    LabeledContent("App", value: "\(r.capability.device.appVersion) (\(r.capability.device.appBuild))")
                    LabeledContent("Schema", value: "\(r.format) v\(r.schemaVersion)")
                    if let free = r.availableCapacityBytesAtOpen {
                        LabeledContent("Free at open", value: "\(free / 1_000_000) MB")
                    }
                    ForEach(r.excluded, id: \.sensor) { e in
                        Text("\(e.sensor) excluded — \(e.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(stations, id: \.stationIndex) { st in
                Section("Station \(st.stationIndex)\(st.poseIntent.map { " · \($0)" } ?? "")") {
                    if let m = st.motion {
                        Text(String(format: "%@ · gyro p50 %.5f p99 %.5f max %.5f",
                                    m.advisory.operatorNote, m.gyroP50, m.gyroP99, m.gyroMax))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(st.sensorSwaps, id: \.toSensor) { s in
                        Text("\(s.fromSensor ?? "open") → \(s.toSensor): \(Int(s.durationSeconds * 1000)) ms")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(st.brackets, id: \.bracketIndex) { b in
                        if let set = b.captureSet {
                            Text("\(b.sensor) · \(set.generator.describe) · \(b.executionMode ?? "?")")
                                .font(.caption).bold()
                        }
                        ForEach(b.droppedRungs, id: \.reason) { d in
                            Text("dropped \(d.spec.shutterLabel) ISO \(Int(d.spec.iso)) — \(d.reason)")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        ForEach(b.frames, id: \.filename) { f in
                            BrowsedFrame(sessionId: sessionId, frame: f)
                        }
                    }
                }
            }
        }
        .navigationTitle(sessionId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { export() } label: {
                if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
            }
            .disabled(exporting)
        }
        .sheet(item: $archive) { ShareSheet(items: [$0.url]) }
        .onAppear {
            record = SessionStore.loadSession(sessionId)
            let loaded = SessionStore.loadStationsDetailed(sessionId)
            stations = loaded.stations
            unreadable = loaded.unreadable
        }
    }

    /// #11 keeps Files and a cable as the primary transfer route. This is the
    /// in-app path, because AirDropping a folder out of Files is awkward and a
    /// session is a folder by design. Zipping runs off the main actor: a
    /// three-sensor scene is ~2 GB.
    private func export() {
        exporting = true
        exportError = nil
        let id = sessionId
        Task.detached(priority: .userInitiated) {
            do {
                let url = try SessionExport.archive(sessionId: id)
                await MainActor.run { archive = ExportedArchive(url: url); exporting = false }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    exporting = false
                }
            }
        }
    }
}

/// One frame: its parameters, its clipping numbers, and the preview the file
/// already carries.
private struct BrowsedFrame: View {
    let sessionId: String
    let frame: FrameRecord
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let t = thumbnail {
                    Image(uiImage: t).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                        .overlay(Text("no\nembedded\npreview").font(.system(size: 7))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary))
                }
            }
            .frame(width: 56, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text(frame.filename).font(.system(size: 9)).monospaced().foregroundStyle(.secondary)
                Text(String(format: "req %.5fs ISO %.0f", frame.requested.shutterSeconds, frame.requested.iso))
                    .font(.caption2).monospaced()
                if let d = frame.dng.exposureTimeSeconds {
                    Text(String(format: "dng %.5fs ISO %d", d, frame.dng.iso ?? 0))
                        .font(.caption2).monospaced()
                }
                if let c = frame.clipping {
                    ClippingBars(stats: c)
                    if c.isSaturated {
                        Text("saturated: "
                             + c.saturatedChannels.map(\.colour).joined(separator: ", "))
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
            }
        }
        .onAppear { thumbnail = SessionStore.embeddedThumbnail(sessionId: sessionId, filename: frame.filename) }
    }
}
