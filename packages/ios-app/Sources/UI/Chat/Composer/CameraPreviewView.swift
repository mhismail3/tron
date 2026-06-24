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

#if DEBUG
struct CameraDebugSurface: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.16, blue: 0.95),
                        Color(red: 0.92, green: 0.16, blue: 0.22),
                        Color(red: 0.06, green: 0.78, blue: 0.42)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { index in
                        Rectangle()
                            .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.12) : Color.black.opacity(0.12))
                            .frame(height: geometry.size.height / 12)
                    }
                }
            }
        }
    }
}
#endif
