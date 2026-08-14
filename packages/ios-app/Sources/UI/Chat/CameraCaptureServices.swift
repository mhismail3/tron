@preconcurrency import AVFoundation

struct CameraSessionConfiguration: @unchecked Sendable {
    let session: AVCaptureSession
    let photoOutput: AVCapturePhotoOutput
    let hasTorch: Bool
}

struct CameraPhotoCaptureRequest: @unchecked Sendable {
    let output: AVCapturePhotoOutput
    let settings: AVCapturePhotoSettings
    let delegate: any AVCapturePhotoCaptureDelegate
}

@MainActor
protocol CameraSessionProviding: AnyObject {
    func configure(
        position: AVCaptureDevice.Position,
        completion: @escaping @MainActor @Sendable (CameraSessionConfiguration?) -> Void
    )
    func start(_ session: AVCaptureSession)
    func stop(_ session: AVCaptureSession)
    func setTorch(
        on: Bool,
        session: AVCaptureSession,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    )
    func capturePhoto(_ request: CameraPhotoCaptureRequest)
}

@MainActor
final class SystemCameraSessionProvider: CameraSessionProviding {
    private let queue = DispatchQueue(label: "app.tron.camera.capture", qos: .userInitiated)

    func configure(
        position: AVCaptureDevice.Position,
        completion: @escaping @MainActor @Sendable (CameraSessionConfiguration?) -> Void
    ) {
        queue.async {
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .photo
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .builtInDualCamera,
                    .builtInDualWideCamera,
                    .builtInTripleCamera,
                    .builtInTrueDepthCamera,
                ],
                mediaType: .video,
                position: position
            )
            guard let camera = discovery.devices.first,
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                Task { @MainActor in completion(nil) }
                return
            }
            session.addInput(input)
            let output = AVCapturePhotoOutput()
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            let configuration = CameraSessionConfiguration(
                session: session,
                photoOutput: output,
                hasTorch: camera.hasTorch
            )
            Task { @MainActor in completion(configuration) }
        }
    }

    func start(_ session: AVCaptureSession) {
        queue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop(_ session: AVCaptureSession) {
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func setTorch(
        on: Bool,
        session: AVCaptureSession,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        queue.async {
            let enabled: Bool
            if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
               device.hasTorch {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if on { try device.setTorchModeOn(level: 1) }
                    else { device.torchMode = .off }
                    enabled = device.torchMode == .on
                } catch {
                    enabled = false
                }
            } else {
                enabled = false
            }
            Task { @MainActor in completion(enabled) }
        }
    }

    func capturePhoto(_ request: CameraPhotoCaptureRequest) {
        queue.async {
            request.output.capturePhoto(with: request.settings, delegate: request.delegate)
        }
    }
}
