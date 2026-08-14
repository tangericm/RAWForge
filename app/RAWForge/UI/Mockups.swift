#if DEBUG
import SwiftUI

/// Design mockups, for looking at rather than shipping.
///
/// These are static views with plausible hardcoded data, rendered on a
/// simulator so a proposed screen can be judged as a picture instead of as a
/// paragraph. They are compiled only in debug builds and reached only through
/// an environment variable, so nothing here can appear in a real run:
///
///     SIMCTL_CHILD_RAWFORGE_MOCKUP=1 xcrun simctl launch <sim> com.tangericm.rawforge
///
/// They live on a design branch, not on main.
enum Mockup: Int, CaseIterable {
    case stationTimeline = 1
    case quickCapture = 2
    case characterisation = 3
    case frameReview = 4

    @ViewBuilder var view: some View {
        switch self {
        case .stationTimeline: MockStationTimeline()
        case .quickCapture:    MockQuickCapture()
        case .characterisation: MockCharacterisation()
        case .frameReview:     MockFrameReview()
        }
    }

    static var requested: Mockup? {
        guard let raw = ProcessInfo.processInfo.environment["RAWFORGE_MOCKUP"],
              let n = Int(raw) else { return nil }
        return Mockup(rawValue: n)
    }
}

// MARK: - 1. The station as a schedule

/// **The proposal: the plan *is* the timeline.**
///
/// Today the shot list is a list and the timeline is a separate screen behind
/// it. That splits one idea in two — what you are shooting, and when it
/// happens are the same fact — and it hides the costs that are easiest to
/// forget, which are the ones you did not add on purpose: the swap, the
/// settle, the seam.
///
/// Blocks are drawn to scale in time. A set that takes eight seconds is
/// visibly eight times a set that takes one, and the ladder's shape is drawn
/// from its own rungs, so a badly-centred sweep is visible before it is shot
/// rather than after.
private struct MockStationTimeline: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    block(.swap, "Swap to 1x", "0.40 s · pose held, nothing shot", seconds: 0.4)
                    block(.settle, "Settle", "0.40 s · measured transient decay", seconds: 0.4)
                    ladderBlock(name: "ladder-7×1stop", sensor: "1x", frames: 7,
                                detail: "1/500 → 1/8 · one request", seconds: 0.9,
                                rungs: [0.25, 0.35, 0.5, 0.65, 0.8, 0.9, 1.0])
                    block(.swap, "Swap to tele", "0.40 s", seconds: 0.4)
                    block(.settle, "Settle", "0.40 s", seconds: 0.4)
                    ladderBlock(name: "repeat-16", sensor: "tele", frames: 16,
                                detail: "1/250 flat · 2 requests, 1 seam", seconds: 1.6,
                                rungs: Array(repeating: 0.6, count: 16), seamAfter: 8)
                    addBlock
                }
                .padding(.horizontal, 16)
            }
            .safeAreaInset(edge: .bottom) { budgetBar }
            .navigationTitle("Station plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Text("Done").bold() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Drawn to scale. The blocks you did not add — swaps, settles, seams — "
                 + "are the ones that cost the most.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private enum Kind { case swap, settle }

    private func block(_ kind: Kind, _ title: String, _ detail: String,
                       seconds: Double) -> some View {
        HStack(alignment: .top, spacing: 10) {
            rail(tint: kind == .swap ? .purple : .blue, height: max(18, seconds * 26))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: kind == .swap ? "arrow.triangle.swap" : "hand.raised.fill")
                        .font(.caption2)
                    Text(title).font(.caption).bold()
                }
                .foregroundStyle(kind == .swap ? Color.purple : Color.blue)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: max(30, seconds * 26))
    }

    /// The rungs are drawn from the set's own exposures, so the ladder's shape
    /// is legible: a sweep that is not centred where it was meant to be looks
    /// wrong here rather than in the files two hours later.
    private func ladderBlock(name: String, sensor: String, frames: Int, detail: String,
                             seconds: Double, rungs: [Double], seamAfter: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            rail(tint: .accentColor, height: max(56, seconds * 26))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name).font(.callout).bold()
                    Text(sensor).font(.caption2).monospaced()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Text("\(frames)f").font(.caption2).monospaced().foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(rungs.enumerated()), id: \.offset) { i, h in
                        if let seam = seamAfter, i == seam {
                            Rectangle().fill(.orange)
                                .frame(width: 2, height: 30)
                                .padding(.horizontal, 2)
                        }
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: 9, height: 6 + h * 26)
                    }
                    Spacer()
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                if seamAfter != nil {
                    Label("seam · 0.57 s — past this sensor's 8-frame bracket ceiling",
                          systemImage: "rectangle.split.2x1")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func rail(tint: Color, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
        }
        .frame(width: 8, height: height)
    }

    private var addBlock: some View {
        HStack(spacing: 10) {
            rail(tint: .secondary, height: 30)
            Label("Add a set", systemImage: "plus.circle.fill")
                .font(.callout)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
        .padding(.top, 4).padding(.bottom, 20)
    }

    private var budgetBar: some View {
        HStack(spacing: 0) {
            figure("23", "frames")
            Divider().frame(height: 26)
            figure("4.5 s", "hold the pose")
            Divider().frame(height: 26)
            figure("230 MB", "on disk")
            Divider().frame(height: 26)
            VStack(spacing: 1) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                Text("fits").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func figure(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.callout).monospaced().bold()
            Text(l).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2. Quick capture

/// **The proposal: a way in that needs no protocol at all.**
///
/// Today the first run is a wall — no protocols exist, so the shot list cannot
/// be built, so no station can be declared, so nothing can be shot until
/// something has been authored. That is correct for the instrument and fatal
/// for adoption.
///
/// Quick offers three named intents that expand to real, named, versioned
/// protocols the moment they fire, so nothing about the record is weaker. The
/// mode switch is the only new concept, and Protocol mode is exactly today's
/// screen.
private struct MockQuickCapture: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("", selection: .constant(0)) {
                    Text("Quick").tag(0)
                    Text("Protocol").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 10)

                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "camera.metering.matrix")
                                .font(.system(size: 26)).foregroundStyle(.secondary)
                            Text("1x · viewfinder").font(.caption2).foregroundStyle(.secondary)
                        })
                    .padding(.horizontal, 12)

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        intent("Bracket", "7 frames\n±3 stops", selected: true)
                        intent("Burst", "16 frames\nidentical", selected: false)
                        intent("Single", "1 frame\nas set", selected: false)
                    }
                    VStack(spacing: 2) {
                        Text("7 frames · 0.9 s · 70 MB").font(.caption).monospaced()
                        Text("saved as quick-bracket v3 — a real protocol, re-runnable later")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Button {} label: {
                        HStack {
                            Image(systemName: "camera.aperture")
                            Text("Capture").bold()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down").font(.system(size: 9))
                        Text("Sensors, exposure, advanced").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                .background(.regularMaterial)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
            }
        }
        .preferredColorScheme(.dark)
    }

    private func intent(_ title: String, _ detail: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption).bold()
            Text(detail).font(.system(size: 9)).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

// MARK: - 3. Characterising this device

/// **The proposal: measure this phone instead of trusting an iPhone 15 Pro.**
///
/// Seven timing and size constants are currently hardcoded from one device.
/// They are honest there and wrong everywhere else: a 12-frame ceiling, a
/// different frame period, a 48 MP versus 12 MP file size all move the plan,
/// and the plan is what the operator trusts when deciding whether to hold a
/// pose.
///
/// The app already knows how to measure all of them — the numbers came from
/// runs like these. A characterisation run makes that a feature rather than a
/// thing that happened once on my desk.
private struct MockCharacterisation: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This device has not been characterised.")
                            .font(.callout).bold()
                        Text("Timing and file-size estimates are currently borrowed from a "
                             + "reference iPhone 15 Pro. They will be wrong here by an unknown "
                             + "amount — which is worse than being absent, because a plan reads "
                             + "as authoritative.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button {} label: {
                            Label("Characterise · about 40 s, 24 frames",
                                  systemImage: "ruler")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }

                Section("What it measures") {
                    measure("Frame period", "33.4 ms", "borrowed", done: true)
                    measure("Bracket seam", "567 ms", "borrowed", done: true)
                    measure("Sensor swap", "400 ms", "borrowed", done: false)
                    measure("Sequential overhead", "233 ms", "borrowed", done: false)
                    measure("Frame size", "10.0 MB avg · 30.7 MB max", "borrowed", done: false)
                    measure("Stillness decay", "0.4 s", "borrowed", done: false)
                }

                Section {
                    Text("Runs with the lens capped or not — none of it depends on the scene. "
                         + "Results are written into every session header, so a file says which "
                         + "device profile it was planned against.")
                        .font(.caption2).foregroundStyle(.secondary)
                } header: {
                    Text("How")
                }

                Section("Community profiles") {
                    profile("iPhone 15 Pro", "measured here", current: true)
                    profile("iPhone 13 mini", "contributed · 12 MP, ceiling 8", current: false)
                    profile("iPhone SE (3rd gen)", "contributed · single sensor", current: false)
                    Text("Anonymous, opt-in, and only ever numbers about hardware — never "
                         + "frames, never locations.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("This device")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func measure(_ name: String, _ value: String, _ source: String, done: Bool) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                Text(value).font(.caption2).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            Text(source).font(.system(size: 9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    private func profile(_ name: String, _ detail: String, current: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if current { Image(systemName: "iphone").foregroundStyle(.tint) }
        }
    }
}

// MARK: - 4. Did I clip?

/// **The proposal: answer the one question every operator has, on device.**
///
/// The app already computes a full 16-bit histogram per CFA channel over the
/// active area of every frame — this is the payload, not the preview, so
/// nothing here crosses #12's line. It is currently shown as six-decimal
/// numbers in a list.
///
/// The same numbers as bars answer "did I clip, and where" in about a second,
/// which is the difference between finding out at the pose and finding out on
/// a workstation after the light has changed.
private struct MockFrameReview: View {
    private let frames: [(String, Double, Bool)] = [
        ("1/500", 0.18, false), ("1/250", 0.31, false), ("1/125", 0.47, false),
        ("1/60", 0.66, false), ("1/30", 0.83, false), ("1/15", 0.96, true),
        ("1/8", 1.0, true),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ladder-7×1stop · 1x · 7 frames").font(.callout).bold()
                        Text("Computed from the Bayer payload over the active area — not from "
                             + "the viewfinder.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    ForEach(Array(frames.enumerated()), id: \.offset) { _, f in
                        frameRow(f.0, level: f.1, clipped: f.2)
                    }

                    Label("2 of 7 rungs clipped on the green channels. The ladder is "
                          + "centred about a stop hot for this scene.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(10)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Button {} label: {
                            Label("Re-shoot 1 stop down", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        Button {} label: {
                            Label("Keep", systemImage: "checkmark").font(.caption)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Station 3")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func frameRow(_ label: String, level: Double, clipped: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption2).monospaced()
                .frame(width: 42, alignment: .trailing)
            VStack(spacing: 2) {
                bar(.red, level * 0.9, clipped: clipped)
                bar(.green, level, clipped: clipped)
                bar(.blue, level * 0.7, clipped: false)
            }
            Image(systemName: clipped ? "exclamationmark.octagon.fill" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(clipped ? .red : .green)
        }
    }

    /// The channel keeps its own colour whether or not it clipped — recolouring
    /// a clipped bar red makes "the green channel clipped" unreadable, since
    /// the bar that clipped is then the same colour as the red channel. The
    /// clip is marked at the ceiling instead, which is also where it happened.
    private func bar(_ tint: Color, _ level: Double, clipped: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: geo.size.width * min(level, 1))
                if clipped && level >= 0.95 {
                    // A hatched cap at the ceiling: the pixels that went past it
                    // are the ones that no longer carry information.
                    HStack(spacing: 0) {
                        Spacer()
                        ZStack {
                            Capsule().fill(.white.opacity(0.9))
                            Text("clip").font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.black)
                        }
                        .frame(width: 26)
                    }
                }
            }
        }
        .frame(height: 7)
    }
}
#endif
