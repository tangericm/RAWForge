import SwiftUI

/// The capture screen: a viewfinder, what the flow is doing, and one button.
///
/// It is laid out as an instrument rather than a form because that is what it
/// is used as — held at arm's length, at a pose, often in the dark. The
/// viewfinder is the largest thing on screen, the phase is legible without
/// reading, and the single action is under the thumb. Everything that is
/// *planning* rather than *shooting* — the shot list, the estimates, the
/// protocol picker — lives in a sheet, because it is done before the walk and
/// not at the pose.
///
/// The phase line is the whole design in one sentence. Every wait it names is a
/// wait the operator cannot skip — stillness has no override, nothing fires
/// before the exposure has settled — so saying *why* the app is busy is the
/// difference between an instrument and a frozen screen.
struct CaptureFlowView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var station: StationController
    /// Jumps to the console. A fault is the moment the log is worth reading,
    /// and making the operator find the tab is making them find it later.
    var showConsole: () -> Void = {}
    @State private var showingPlan = {
        #if DEBUG
        return DemoSeed.value == "1" || DemoSeed.wantsStarter
        #else
        return false
        #endif
    }()
    @State private var showingFault = true
    @State private var confirmingAbandon = false

    init(model: CaptureModel, showConsole: @escaping () -> Void = {}) {
        self.model = model
        self.station = model.station
        self.showConsole = showConsole
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                viewfinder
                Spacer(minLength: 0)
                deck
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingPlan = true } label: {
                    Label("Plan", systemImage: "list.bullet.rectangle")
                }
                .disabled(model.report?.canCapture != true)
            }
        }
        .sheet(isPresented: $showingPlan) { PlanSheet(model: model) }
        .confirmationDialog("Abandon this station?", isPresented: $confirmingAbandon,
                            titleVisibility: .visible) {
            Button("Abandon station \(station.stationIndex)", role: .destructive) {
                station.abortStation(.abandoned)
            }
            Button("Keep shooting", role: .cancel) {}
        } message: {
            Text("Its \(station.pendingBrackets.reduce(0) { $0 + $1.frames.count }) frame(s) so far "
                 + "will be deleted. Stations already banked are untouched.")
        }
        .onAppear { station.startFlow() }
        .onChange(of: station.lastFault) { showingFault = station.lastFault != nil }
    }

    // MARK: - Header

    /// Session, station and health, in the order they are asked about.
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let s = station.session {
                    Text(s.sessionId).font(.caption2).monospaced().foregroundStyle(.secondary)
                    if station.phase.isInStation {
                        Text("Station \(station.stationIndex)"
                             + (station.poseIntent.isEmpty ? "" : " · \(station.poseIntent)"))
                            .font(.caption).bold()
                    }
                } else {
                    Text("No session").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            healthPill
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var healthPill: some View {
        let warn = model.health.thermalWarning || model.health.batteryWarning
        return Label(model.health.summary,
                     systemImage: warn ? "thermometer.high" : "bolt.fill")
            .font(.caption2)
            .foregroundStyle(warn ? .orange : .secondary)
            .labelStyle(.titleAndIcon)
    }

    // MARK: - Viewfinder

    /// Shown at the sensor's own aspect rather than cropped to fill. A framing
    /// aid that hides part of the frame is worse than none — the operator would
    /// compose to edges that are not the edges being captured.
    private var viewfinder: some View {
        ViewfinderPanel(model: model)
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) { setProgress }
    }

    /// One pip per set, so how far through the station it is can be read
    /// without counting.
    @ViewBuilder private var setProgress: some View {
        if station.phase.isInStation && station.shotList.entries.count > 1 {
            HStack(spacing: 5) {
                ForEach(Array(station.shotList.entries.enumerated()), id: \.element.id) { i, _ in
                    Capsule()
                        .fill(i < station.shotList.cursor ? Color.accentColor
                              : i == station.shotList.cursor ? Color.accentColor.opacity(0.5)
                              : Color.white.opacity(0.25))
                        .frame(width: i == station.shotList.cursor ? 18 : 8, height: 4)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 10)
        }
    }

    // MARK: - Control deck

    private var deck: some View {
        VStack(spacing: 12) {
            if let f = station.lastFault, showingFault { faultBanner(f) }
            // The set just shot, while the light and the pose are still there.
            if let last = station.pendingBrackets.last, !last.frames.isEmpty, !station.busy {
                SetClippingSummary(frames: last.frames)
            }
            phaseLine
            primaryButton
            secondaryRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
    }

    private var phaseLine: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if station.busy {
                    ProgressView().controlSize(.small)
                }
                Text(station.phase.title)
                    .font(.subheadline).bold()
                Spacer()
                if station.phase.isInStation, let e = station.stationEstimateSeconds {
                    Text("~\(SessionEstimate.formatDuration(e)) planned")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // The most specific thing known, in priority order: what the capture
            // is doing right now, then what the wait is, then why the phase
            // exists at all.
            Text(detail)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .animation(.none, value: detail)
        }
    }

    private var detail: String {
        if !station.progress.isEmpty { return station.progress }
        if !station.stillnessLive.isEmpty { return station.stillnessLive }
        return station.phase.note
    }

    private var primaryButton: some View {
        let action = station.primaryAction
        return Button {
            station.performPrimaryAction()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                Text(action.title).bold()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(action.isTerminal ? .green : .accentColor)
        .disabled(!action.isEnabled || station.busy)
        .animation(.easeInOut(duration: 0.15), value: action)
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            Button { showingPlan = true } label: {
                Label(planLabel, systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(model.report?.canCapture != true)

            Spacer()

            if station.phase == .sessionOpen {
                Button("Close session") { station.closeSession() }
                    .font(.caption).buttonStyle(.bordered)
            }
            if station.phase.isInStation && !station.shotList.canClose {
                // Present at every point a station is in flight, because the
                // reason to stop is usually that the pose is already lost.
                Button(role: .destructive) {
                    confirmingAbandon = true
                } label: {
                    Label("Abandon", systemImage: "xmark").font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var planLabel: String {
        let n = station.shotList.entries.count
        if n == 0 { return "Build shot list" }
        return "\(n) set\(n == 1 ? "" : "s") · \(station.shotList.totalFrames) frames"
    }

    private func faultBanner(_ f: StationFault) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Station aborted — \(f.operatorNote)").font(.caption).bold()
                Text("Its frames were deleted. Stations already banked survive, so there "
                     + "is no partial state to interpret later.")
                    .font(.caption2).foregroundStyle(.secondary)
                if f != .abandoned {
                    Button { showConsole() } label: {
                        Label("What happened", systemImage: "text.alignleft").font(.caption2)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            Button { showingFault = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
