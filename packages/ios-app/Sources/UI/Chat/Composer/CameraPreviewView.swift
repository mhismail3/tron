import SwiftUI
@preconcurrency import AVFoundation

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

class CameraPreviewUIView: UIView {
    var session: AVCaptureSession? {
        didSet {
            guard let session = session else { return }
            previewLayer?.session = session
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        previewLayer?.videoGravity = .resizeAspectFill
        previewLayer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let extendedBounds = bounds.inset(by: UIEdgeInsets(
            top: -safeAreaInsets.top,
            left: -safeAreaInsets.left,
            bottom: -safeAreaInsets.bottom,
            right: -safeAreaInsets.right
        ))
        previewLayer?.frame = extendedBounds
    }
}
