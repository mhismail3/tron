import SwiftUI
@preconcurrency import AVFoundation

struct QRCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let authorization: any CameraAuthorizationProviding
    private let capture: any QRCodeCaptureSessionProviding
    private var authorizationTask: Task<Void, Never>?
    private var admitted = false

    init(
        authorization: any CameraAuthorizationProviding = SystemCameraAuthorizationProvider(),
        capture: any QRCodeCaptureSessionProviding = SystemQRCodeCaptureSessionProvider()
    ) {
        self.authorization = authorization
        self.capture = capture
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        authorization = SystemCameraAuthorizationProvider()
        capture = SystemQRCodeCaptureSessionProvider()
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        authorizationTask = Task { [weak self] in
            await self?.authorizeAndStart()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        capture.previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        authorizationTask?.cancel()
        authorizationTask = nil
        capture.stop()
    }

    func admit(_ code: String) {
        guard !admitted else { return }
        admitted = true
        authorizationTask?.cancel()
        authorizationTask = nil
        capture.stop()
        onCode?(code)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else {
            return
        }
        admit(code)
    }

    private func authorizeAndStart() async {
        let authorized: Bool
        switch authorization.authorizationStatus() {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await authorization.requestAccess()
        case .denied, .restricted:
            authorized = false
        @unknown default:
            authorized = false
        }
        guard authorized, !Task.isCancelled, capture.configure(delegate: self) else { return }
        if let layer = capture.previewLayer {
            view.layer.addSublayer(layer)
            layer.frame = view.bounds
        }
        capture.start()
    }
}
