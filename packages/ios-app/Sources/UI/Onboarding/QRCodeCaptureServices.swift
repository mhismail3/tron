@preconcurrency import AVFoundation

@MainActor
protocol QRCodeCaptureSessionProviding: AnyObject {
    var previewLayer: AVCaptureVideoPreviewLayer? { get }
    func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate) -> Bool
    func start()
    func stop()
}

@MainActor
final class SystemQRCodeCaptureSessionProvider: QRCodeCaptureSessionProviding {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.tron.camera.qr", qos: .userInitiated)
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false

    func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate) -> Bool {
        if configured { return true }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        configured = true
        return true
    }

    func start() {
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}
