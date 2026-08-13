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

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("No sessions yet.").foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.self) { id in
                NavigationLink(destination: SessionDetail(sessionId: id)) {
                    SessionRow(sessionId: id)
                }
            }
        }
        .navigationTitle("Sessions")
        .onAppear { sessions = SessionStore.existingSessionIds().reversed() }
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

    var body: some View {
        List {
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
        .onAppear {
            record = SessionStore.loadSession(sessionId)
            stations = SessionStore.loadStations(sessionId)
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
                if let c = frame.clipping, c.unavailableReason == nil {
                    ForEach(c.channels, id: \.cfaPosition) { ch in
                        Text(String(format: "%@ p50 %.3f p99 %.3f · ceil %.3f%% · black %.3f%%",
                                    ch.colour, ch.p50Normalised, ch.p99Normalised,
                                    100 * ch.fractionAtOrAboveObservedCeiling,
                                    100 * ch.fractionAtOrBelowBlack))
                            .font(.system(size: 9)).monospaced()
                    }
                } else if let why = frame.clipping?.unavailableReason {
                    Text("clipping stats absent — \(why)")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
        }
        .onAppear { thumbnail = SessionStore.embeddedThumbnail(sessionId: sessionId, filename: frame.filename) }
    }
}
