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

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// The viewfinder with the caveat attached to it, because a preview that looks
/// like the data is exactly the confusion #12 was guarding against.
struct ViewfinderPanel: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(spacing: 4) {
            CameraPreview(session: model.rig.session)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if !model.rig.session.isRunning {
                        Text("viewfinder idle")
                            .font(.caption2).padding(4)
                            .background(.ultraThinMaterial, in: Capsule()).padding(6)
                    }
                }
            Text("Framing only — tone-mapped preview, not the Bayer payload. "
                 + "No statistic is taken from this image.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
