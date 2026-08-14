import SwiftUI

/// The flight recorder, on screen.
///
/// This exists so a fault can be read **at the pose**, while the thing that
/// caused it is still set up, rather than on a laptop an hour later. That is
/// why it tails live, why the filters are one tap, and why the share button
/// hands over the file rather than a screenshot of it.
struct LogConsoleView: View {
    @State private var entries: [DebugLog.Entry] = []
    @State private var minimum: DebugLog.Level = .trace
    @State private var mutedCategories: Set<DebugLog.Category> = []
    @State private var search = ""
    @State private var follow = true
    @State private var shared: ExportedArchive?
    @State private var tally = (warnings: 0, errors: 0, total: 0)
    @State private var lastGeneration: UInt64 = .max
    /// How many matching lines have arrived since following was turned off.
    @State private var pendingBelow = 0
    /// The newest entry the operator has actually seen.
    @State private var seenThrough: UInt64 = 0

    private var categories: Set<DebugLog.Category> {
        Set(DebugLog.Category.allCases).subtracting(mutedCategories)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            stream
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { shareCurrent() } label: {
                        Label("Share this run's log", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink { LogFilesView() } label: {
                        Label("Earlier runs", systemImage: "clock.arrow.circlepath")
                    }
                    Button { UIPasteboard.general.string = visibleText() } label: {
                        Label("Copy what's shown", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        DebugLog.shared.clearRing(); refresh(force: true)
                    } label: {
                        Label("Clear the screen", systemImage: "eraser")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
        .task { await tail() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Level", selection: $minimum) {
                    ForEach(DebugLog.Level.allCases, id: \.self) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: minimum) { refresh(force: true) }

                // Following is what you want while something is going wrong and
                // exactly what you don't want while reading back what did. It
                // used to be an unlabelled arrow, which looked like it did
                // nothing — with a screenful of lines there is no scrolling to
                // see either way, so the only feedback was the icon changing.
                Button {
                    follow.toggle()
                    if follow { pendingBelow = 0 }
                } label: {
                    Label(follow ? "Live" : "Paused",
                          systemImage: follow ? "arrow.down.to.line" : "pause.fill")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(follow ? .accentColor : .secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(DebugLog.Category.allCases, id: \.self) { c in
                        let on = !mutedCategories.contains(c)
                        Button {
                            if on { mutedCategories.insert(c) } else { mutedCategories.remove(c) }
                            refresh(force: true)
                        } label: {
                            Text(c.rawValue)
                                .font(.caption2).monospaced()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(on ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: Capsule())
                                .overlay(Capsule().stroke(.quaternary))
                                .foregroundStyle(on ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("filter text", text: $search)
                    .font(.caption).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: search) { refresh(force: true) }
                if !search.isEmpty {
                    Button { search = ""; refresh(force: true) } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entries.count)/\(tally.total)")
                    .font(.caption2).monospaced().foregroundStyle(.secondary)
                if tally.errors > 0 {
                    Label("\(tally.errors)", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
                if tally.warnings > 0 {
                    Label("\(tally.warnings)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Stream

    private var stream: some View {
        ScrollViewReader { proxy in
            scrollBody(proxy)
                // Paused with new lines arriving is the one state where the
                // screen is silently out of date, so it says so and offers the
                // way back rather than leaving it to be noticed.
                .overlay(alignment: .bottom) {
                    if !follow && pendingBelow > 0 {
                        Button {
                            follow = true
                            pendingBelow = 0
                            withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                        } label: {
                            Label("\(pendingBelow) new", systemImage: "arrow.down")
                                .font(.caption2).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(.quaternary))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 10)
                    }
                }
        }
    }

    private func scrollBody(_ proxy: ScrollViewProxy) -> some View {
        Group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Text(DebugLog.shared.tally().total == 0
                             ? "Nothing logged yet."
                             : "Nothing matches these filters.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(entries) { e in
                        row(e).id(e.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .onChange(of: entries.count) {
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "log-bottom"

    private func row(_ e: DebugLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle().fill(tint(e.level)).frame(width: 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(e.clock).font(.system(size: 9)).monospaced().foregroundStyle(.secondary)
                    Text(e.category.rawValue).font(.system(size: 9)).monospaced()
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                Text(e.message)
                    .font(.system(size: 11)).monospaced()
                    .foregroundStyle(e.level == .error ? Color.red
                                     : e.level == .warn ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func tint(_ l: DebugLog.Level) -> Color {
        switch l {
        case .trace: return .clear
        case .info:  return .secondary.opacity(0.4)
        case .warn:  return .orange
        case .error: return .red
        }
    }

    // MARK: - Tailing

    /// Polls rather than publishing. The log is written from the session queue,
    /// the motion queue and several detached tasks — pushing each line onto the
    /// main actor would put SwiftUI in the capture path, which is exactly the
    /// kind of coupling the log exists to help debug, not to cause.
    private func tail() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func refresh(force: Bool = false) {
        let g = DebugLog.shared.generation
        guard force || g != lastGeneration else { return }
        lastGeneration = g
        entries = DebugLog.shared.snapshot(minimum: minimum, categories: categories, search: search)
        tally = DebugLog.shared.tally()

        // Counted against what matches the current filters, not against the raw
        // log — "12 new" that turn out to be filtered out would be a lie.
        if follow {
            seenThrough = entries.last?.id ?? seenThrough
            pendingBelow = 0
        } else {
            pendingBelow = entries.filter { $0.id > seenThrough }.count
        }
    }

    private func visibleText() -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    private func shareCurrent() {
        DebugLog.shared.flush()
        if let url = DebugLog.shared.fileURL { shared = ExportedArchive(url: url) }
    }
}

/// Earlier launches, because the interesting one is often the run that died —
/// and that run's file is by definition not the current one.
private struct LogFilesView: View {
    @State private var files: [URL] = []
    @State private var shared: ExportedArchive?

    var body: some View {
        List {
            if files.isEmpty {
                Text("No log files.").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { url in
                Button {
                    shared = ExportedArchive(url: url)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.caption).monospaced()
                            Text(size(url)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Section {
                Text("The newest file is this run. Logs are kept for the last eight launches "
                     + "and swept after that — the sessions are the record, not these.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Earlier runs")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
        .onAppear { DebugLog.shared.flush(); files = DebugLog.allFiles() }
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return bytes < 1024 ? "\(bytes) bytes" : String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
