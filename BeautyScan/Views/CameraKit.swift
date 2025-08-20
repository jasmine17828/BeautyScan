import SwiftUI
import AVFoundation
import Observation

struct CameraView: UIViewRepresentable {
    @Bindable var engine: FaceMeasureEngine

    func makeUIView(context: Context) -> UIView {
        let v = PreviewHostView()
        v.backgroundColor = .black

        let preview = engine.makePreviewLayer()
        v.layer.addSublayer(preview)
        context.coordinator.preview = preview

        let overlay = CAShapeLayer()
        overlay.lineWidth = 2
        overlay.fillColor = UIColor.clear.cgColor
        overlay.strokeColor = UIColor.systemBlue.cgColor
        overlay.lineJoin = .round
        v.layer.addSublayer(overlay)
        context.coordinator.overlay = overlay

        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let host = uiView as? PreviewHostView else { return }
        context.coordinator.layoutLayers(in: host)
        context.coordinator.redraw(measures: engine.measures)
    }

    func makeCoordinator() -> Coord { Coord() }

    final class Coord {
        weak var preview: AVCaptureVideoPreviewLayer?
        weak var overlay: CAShapeLayer?

        func layoutLayers(in host: PreviewHostView) {
            guard let preview, let overlay else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview.frame = host.bounds
            overlay.frame = host.bounds
            CATransaction.commit()
        }

        func redraw(measures: [FaceMeasureEngine.Measure]) {
            guard let preview, let overlay else { return }
            let path = UIBezierPath()

            func layerPoint(from01 p01: CGPoint) -> CGPoint {
                preview.layerPointConverted(fromCaptureDevicePoint: p01)
            }

            for m in measures {
                for (a01, b01) in m.measureLines01 {
                    path.move(to: layerPoint(from01: a01))
                    path.addLine(to: layerPoint(from01: b01))
                }
                for p01 in m.points01 {
                    let p = layerPoint(from01: p01)
                    path.move(to: p)
                    path.addArc(withCenter: p, radius: 2.5, startAngle: 0, endAngle: .pi*2, clockwise: true)
                }
            }

            CATransaction.begin(); CATransaction.setDisableActions(true)
            overlay.path = path.cgPath
            CATransaction.commit()
        }
    }
}

final class PreviewHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}
