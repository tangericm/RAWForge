import SwiftUI
import Combine
import UIKit   // UIPasteboard

/// Owns the rig and the probe suites, and drives them from the buttons. One
/// throwaway controller — no architecture intended.
@MainActor
final class ProbeController: ObservableObject {
    @Published var prepared = false
    @Published var busy = false

    let log: ProbeLog
    private let rig = CaptureRig(deviceType: .builtInWideAngleCamera)
    private lazy var bayer = BayerProbes(rig: rig, log: log)
    private lazy var motion = MotionProbes(rig: rig, log: log)
    private var logChanges: AnyCancellable?

    init(log: ProbeLog) {
        self.log = log
        // A nested ObservableObject does not republish through its parent, so
        // without this the transcript only redraws when `busy` flips — i.e. the
        // whole run appears at once, after it has finished. The point of the
        // log is watching a probe as it goes, so forward the child's changes.
        logChanges = log.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func prepare() async {
        guard !prepared else { return }
        busy = true; defer { busy = false }
        prepared = await bayer.prepare()
    }

    func run(_ body: @escaping () async -> Void) async {
        guard prepared else { log.log("not prepared — tap Prepare first"); return }
        busy = true; defer { busy = false }
        await body()
    }

    func runAll() async {
        await run {
            await self.bayer.probeBracketFeasibility()   // 1
            await self.bayer.probeNoiseReduction()        // 14
            await self.bayer.probeWhiteBalancePath()      // 3
            await self.motion.probeStillness()            // 21
            await self.motion.probeSamplingUnderCapture() // 19
            await self.motion.probeTimebase()             // 20
            self.log.section("done")
        }
    }

    // individual runners
    func item1()  async { await run { await self.bayer.probeBracketFeasibility() } }
    func item3()  async { await run { await self.bayer.probeWhiteBalancePath() } }
    func item14() async { await run { await self.bayer.probeNoiseReduction() } }
    func item21() async { await run { await self.motion.probeStillness() } }
    func item19() async { await run { await self.motion.probeSamplingUnderCapture() } }
    func item20() async { await run { await self.motion.probeTimebase() } }
}

struct ContentView: View {
    @StateObject private var ctl = ProbeController(log: ProbeLog())

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RAWForge device probe — #14 spike")
                .font(.headline)
            Text("Physical iPhone 15 Pro only. Tap Prepare, then Run all, then long-press the log to copy.")
                .font(.caption).foregroundColor(.secondary)

            HStack {
                button("Prepare", disabled: ctl.prepared) { await ctl.prepare() }
                button("Run all", disabled: !ctl.prepared) { await ctl.runAll() }
                button("Clear") { ctl.log.clear() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    button("1 bracket", disabled: !ctl.prepared) { await ctl.item1() }
                    button("3 WB path", disabled: !ctl.prepared) { await ctl.item3() }
                    button("14 NR", disabled: !ctl.prepared) { await ctl.item14() }
                    button("21 still", disabled: !ctl.prepared) { await ctl.item21() }
                    button("19 sampling", disabled: !ctl.prepared) { await ctl.item19() }
                    button("20 timebase", disabled: !ctl.prepared) { await ctl.item20() }
                }
            }
            if ctl.busy { ProgressView().padding(.top, 2) }
        }
        .padding()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(ctl.log.text.isEmpty ? "no output yet" : ctl.log.text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
                    .id("end")
            }
            .onChange(of: ctl.log.lines.count) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
            .contextMenu {
                Button("Copy all") { UIPasteboard.general.string = ctl.log.text }
            }
        }
    }

    private func button(_ title: String, disabled: Bool = false,
                        _ action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(.bordered)
            .disabled(disabled || ctl.busy)
    }
}
