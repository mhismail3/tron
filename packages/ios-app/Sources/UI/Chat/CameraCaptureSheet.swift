import SwiftUI
import UIKit
@preconcurrency import AVFoundation

@Observable
@MainActor
final class CameraModel: NSObject {
    var isAuthorized = false
    var permissionDenied = false
    var cameraUnavailable = false
    var isTorchOn = false
    var hasTorch = false
    var session: AVCaptureSession?
    var isReady: Bool { isAuthorized && session != nil && !cameraUnavailable && !configuring }

    private var photoOutput: AVCapturePhotoOutput?
    private var position: AVCaptureDevice.Position = .back
    private var completion: ((UIImage?) -> Void)?
    private var configuring = false
    private let queue = DispatchQueue(label: "app.tron.camera.capture", qos: .userInitiated)

    func requestPermissionAndSetup() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            setup()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            permissionDenied = !granted
            if granted { setup() }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    private func setup() {
        guard !configuring else { return }
        configuring = true
        let requestedPosition = position
        queue.async { [weak self] in
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .photo
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera, .builtInTrueDepthCamera],
                mediaType: .video,
                position: requestedPosition
            )
            guard let camera = discovery.devices.first,
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self?.configuring = false; self?.cameraUnavailable = true }
                return
            }
            session.addInput(input)
            let output = AVCapturePhotoOutput()
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async {
                self?.session = session
                self?.photoOutput = output
                self?.hasTorch = camera.hasTorch
                self?.configuring = false
                self?.cameraUnavailable = false
            }
        }
    }

    func stopSession() {
        guard let session else { return }
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func startSession() {
        guard let session else { setup(); return }
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func flipCamera() {
        stopSession()
        session = nil
        photoOutput = nil
        isTorchOn = false
        position = position == .back ? .front : .back
        setup()
    }

    func toggleTorch() {
        guard let device = (session?.inputs.first as? AVCaptureDeviceInput)?.device,
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if isTorchOn { device.torchMode = .off }
            else { try device.setTorchModeOn(level: 1) }
            isTorchOn = device.torchMode == .on
        } catch { isTorchOn = false }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        guard let photoOutput else { finish(nil); return }
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func finish(_ image: UIImage?) {
        let callback = completion
        completion = nil
        callback?(image)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        Task { @MainActor in finish(image) }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        return view
    }
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { nil }
}

/// Historical immersive Tron camera with capture, retake, torch, and camera
/// switching. The resulting image enters the same bounded gateway upload path
/// as photo-library images.
struct CameraCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImageCaptured: (UIImage) -> Void
    @State private var camera = CameraModel()
    @State private var capturedImage: UIImage?

    var body: some View {
        ZStack {
            cameraSurface
                .ignoresSafeArea()

            if camera.permissionDenied || camera.cameraUnavailable {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeDisplay, weight: .semibold))
                    Text(camera.permissionDenied ? "Camera Access Required" : "Camera Unavailable")
                        .font(TronTypography.headline)
                    Button("Close") { dismiss() }
                }
                .foregroundStyle(Color.white)
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color.black.opacity(0.18)).interactive(), in: .circle)
                    .accessibilityLabel("Close camera")
                    Spacer()
                }
                .padding(20)
                Spacer()
                controls.padding(.bottom, 34)
            }
        }
        .background(Color.black)
        .task { await camera.requestPermissionAndSetup() }
        .onDisappear { camera.stopSession() }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
    }

    @ViewBuilder private var cameraSurface: some View {
        if let capturedImage {
            Image(uiImage: capturedImage).resizable().scaledToFill()
        } else if let session = camera.session {
            CameraPreviewView(session: session)
        } else {
            Color.black
        }
    }

    private var controls: some View {
        HStack(spacing: 34) {
            cameraButton(
                icon: camera.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                enabled: capturedImage == nil && camera.hasTorch
            ) { camera.toggleTorch() }

            Button {
                if let capturedImage {
                    onImageCaptured(capturedImage)
                    dismiss()
                } else {
                    camera.capturePhoto { image in
                        guard let image else { return }
                        withAnimation(.smooth(duration: 0.28)) { capturedImage = image }
                        camera.stopSession()
                    }
                }
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.001))
                        .frame(width: 76, height: 76)
                        .glassEffect(.regular.tint((capturedImage == nil ? Color.white : Color.tronEmerald).opacity(0.44)).interactive(), in: .circle)
                    Image(systemName: capturedImage == nil ? "camera.fill" : "checkmark")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(capturedImage == nil && !camera.isReady)
            .accessibilityLabel(capturedImage == nil ? "Capture photo" : "Use photo")

            cameraButton(icon: capturedImage == nil ? "arrow.triangle.2.circlepath.camera" : "arrow.counterclockwise", enabled: true) {
                if capturedImage == nil { camera.flipCamera() }
                else {
                    withAnimation(.smooth(duration: 0.28)) { capturedImage = nil }
                    camera.startSession()
                }
            }
        }
    }

    private func cameraButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 60, height: 60)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.white.opacity(0.12)).interactive(enabled), in: .circle)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.36)
    }
}
