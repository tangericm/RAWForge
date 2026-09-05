import AVFoundation
import SwiftUI
import UIKit

/// A framing viewfinder, and nothing more.
///
/// #12 rules out a live **RAW** preview, and the reason is specific: the
/// viewfinder is never the Bayer payload, so anything live would measure
/// tone-mapped pixels while appearing to measure the data being kept. That
/// forbids a live histogram, a clipping indicator, or any statistic drawn from
/// this stream — and the app derives none.
///
/// It does not forbid *seeing where the camera points*. The line #12 declines
/// to move is that the app may not demosaic, apply colour, or apply white
/// balance **to pixels** — meaning the captured payload. This layer is the
/// system's own preview stream, produced independently of the RAW path and
/// never written anywhere. Without it the instrument is aimed blind, which is
/// not a defensible property of a field tool.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    /// Reports a tap in **`AVCaptureDevice` coordinates**, not view coordinates.
    ///
    /// The conversion has to happen here because the preview layer is the only
    /// thing that knows how the image is rotated and letterboxed inside the
    /// view. Doing the arithmetic in SwiftUI against the view's frame would
    /// work until the preview was drawn at a different aspect, and then aim
    /// autofocus somewhere the operator did not tap (#18).
    var onTapDevicePoint: ((CGPoint) -> Void)?

    /// A point to mark, also in device coordinates — converted back through the
    /// same layer so it lands under the finger that set it.
    var indicatorDevicePoint: CGPoint?

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        if onTapDevicePoint != nil {
            let tap = UITapGestureRecognizer(target: v, action: #selector(PreviewUIView.handleTap))
            v.addGestureRecognizer(tap)
        }
        v.onTapDevicePoint = onTapDevicePoint
        v.indicatorDevicePoint = indicatorDevicePoint
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        uiView.onTapDevicePoint = onTapDevicePoint
        uiView.indicatorDevicePoint = indicatorDevicePoint
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var onTapDevicePoint: ((CGPoint) -> Void)?
        var indicatorDevicePoint: CGPoint? { didSet { positionIndicator() } }

        /// Drawn in UIKit rather than as a SwiftUI overlay for the same reason
        /// the conversion is here: only the layer can put it in the right place.
        private lazy var reticle: UIView = {
            let v = UIView(frame: CGRect(x: 0, y: 0, width: 68, height: 68))
            v.layer.borderColor = UIColor.systemYellow.cgColor
            v.layer.borderWidth = 1.5
            v.layer.cornerRadius = 4
            v.isUserInteractionEnabled = false
            v.isHidden = true
            addSubview(v)
            return v
        }()

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let devicePoint = previewLayer.captureDevicePointConverted(
                fromLayerPoint: g.location(in: self))
            onTapDevicePoint?(devicePoint)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            positionIndicator()
        }

        /// Nothing is drawn unless the conversion can actually be trusted.
        ///
        /// `layerPointConverted(fromCaptureDevicePoint:)` needs a live
        /// connection to know how the image sits inside the view; without one
        /// it returns a point with no relationship to the scene, and the marker
        /// lands in a corner looking authoritative. A marker in the wrong place
        /// is worse than no marker — the operator would believe it.
        private func positionIndicator() {
            guard let p = indicatorDevicePoint,
                  previewLayer.connection?.isEnabled == true,
                  previewLayer.session?.isRunning == true else {
                reticle.isHidden = true
                return
            }
            let converted = previewLayer.layerPointConverted(fromCaptureDevicePoint: p)
            guard bounds.contains(converted) else { reticle.isHidden = true; return }
            reticle.isHidden = false
            reticle.center = converted
        }
    }
}

/// The viewfinder with the caveat attached to it, because a preview that looks
/// like the data is exactly the confusion #12 was guarding against.
///
/// Shown at the sensor's own 4:3 aspect rather than cropped to fill the screen.
/// A framing aid that hides part of the frame is worse than none — the operator
/// would compose to edges that are not the edges being captured.
struct ViewfinderPanel: View {
    @ObservedObject var model: CaptureModel
    @State private var running = false

    var body: some View {
        ZStack {
            // Visibly bounded even with nothing in it. An unlit frame on a black
            // screen reads as a broken app rather than as a viewfinder waiting.
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(running ? 0 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(running ? 0.15 : 0.08), lineWidth: 1))
            CameraPreview(session: model.rig.session)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .opacity(running ? 1 : 0)
            if !running { idleState }
            corners
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay(alignment: .topLeading) { badge }
        .overlay(alignment: .bottomTrailing) { caveat }
        // `isRunning` is a plain AVFoundation property with no publisher, and
        // the session comes up on its own queue — so it is read on a timer
        // rather than pretended to be observable.
        .task {
            while !Task.isCancelled {
                let live = model.rig.session.isRunning
                if live != running { withAnimation(.easeInOut(duration: 0.2)) { running = live } }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text(model.report?.canCapture == true ? "Viewfinder idle" : "No Bayer sensor")
                .font(.caption).foregroundStyle(.secondary)
            if model.report?.canCapture == true {
                Text("Preview pauses during capture.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
    }

    /// Which sensor is actually live — the one thing about the preview that is
    /// load-bearing, since a shot list spanning three sensors swaps underneath
    /// it.
    @ViewBuilder private var badge: some View {
        if running, let s = model.rig.sensor {
            Text(s.rawValue)
                .font(.caption2).bold().monospaced()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
        }
    }

    private var caveat: some View {
        Text("Framing preview · not RAW")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
    }

    /// Framing marks, drawn rather than a full grid: enough to level against an
    /// edge without covering the scene.
    private var corners: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                for x in [w / 3, 2 * w / 3] {
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                }
                for y in [h / 3, 2 * h / 3] {
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(running ? 0.12 : 0), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
