import SwiftUI
@preconcurrency import AVFoundation

/// Custom camera capture sheet with styled UI matching the app aesthetic.
/// Features a square viewport with rounded corners and control buttons.
@available(iOS 26.0, *)
struct CameraCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImageCaptured: (UIImage) -> Void

    @StateObject private var cameraModel = CameraModel()
    @State private var capturedImage: UIImage?
    @State private var showingPreview = false

    var body: some View {
        GeometryReader { geometry in
            let viewportSize = min(geometry.size.width - 56, geometry.size.height - 150)

            VStack(spacing: 16) {
                // Header
                Text("Take Photo")
                    .font(TronTypography.button)
                    .foregroundStyle(.tronEmerald)
                    .padding(.top, 16)

                // Camera viewport - square with rounded corners
                ZStack {
                    if let image = capturedImage, showingPreview {
                        // Preview captured image
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: viewportSize, height: viewportSize)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else if cameraModel.isAuthorized {
                        // Live camera preview
                        CameraPreviewView(session: cameraModel.session)
                            .frame(width: viewportSize, height: viewportSize)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        // Permission denied or loading
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.tronSurfaceElevated)
                            .frame(width: viewportSize, height: viewportSize)
                            .overlay {
                                if cameraModel.permissionDenied {
                                    VStack(spacing: 12) {
                                        Image(systemName: "camera.fill")
                                            .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                                            .foregroundStyle(.tronTextMuted)
                                        Text("Camera Access Required")
                                            .font(TronTypography.subheadline)
                                            .foregroundStyle(.tronTextSecondary)
                                        Text("Enable in Settings")
                                            .font(TronTypography.caption)
                                            .foregroundStyle(.tronTextMuted)
                                    }
                                } else {
                                    ProgressView()
                                        .tint(.tronEmerald)
                                }
                            }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.tronOverlay(0.1), lineWidth: 1)
                        .frame(width: viewportSize, height: viewportSize)
                )

                Spacer(minLength: 0)

                // Control buttons
                controlButtons
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .task {
            await cameraModel.requestPermissionAndSetup()
        }
        .onDisappear {
            cameraModel.stopSession()
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        if showingPreview {
            // Preview mode: Retake, Use Photo
            HStack(alignment: .center, spacing: 32) {
                // Retake
                Button(action: retake) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .frame(width: 52, height: 52)
                }
                .glassEffect(.regular.tint(Color.tronOverlay(0.25)).interactive(), in: .circle)

                // Use Photo - primary action
                Button(action: usePhoto) {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: TronTypography.sizeHero, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                }
                .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.65)).interactive(), in: .circle)

                // Placeholder for symmetry
                Color.clear
                    .frame(width: 52, height: 52)
            }
        } else {
            // Capture mode: Night mode, Capture, Flip
            HStack(spacing: 32) {
                // Night mode (torch)
                Button(action: { cameraModel.toggleTorch() }) {
                    Image(systemName: cameraModel.isTorchOn ? "moon.fill" : "moon")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(cameraModel.isTorchOn ? .tronEmerald : .tronTextPrimary)
                        .frame(width: 52, height: 52)
                }
                .glassEffect(
                    .regular.tint(cameraModel.isTorchOn ? Color.tronEmerald.opacity(0.4) : Color.tronOverlay(0.25)).interactive(),
                    in: .circle
                )
                .disabled(!cameraModel.isAuthorized || !cameraModel.hasTorch)
                .opacity(cameraModel.isAuthorized && cameraModel.hasTorch ? 1 : 0.3)

                // Capture
                Button(action: capturePhoto) {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                        .overlay {
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                        }
                }
                .disabled(!cameraModel.isAuthorized)
                .opacity(cameraModel.isAuthorized ? 1 : 0.3)

                // Flip camera
                Button(action: flipCamera) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .frame(width: 52, height: 52)
                }
                .glassEffect(.regular.tint(Color.tronOverlay(0.25)).interactive(), in: .circle)
                .disabled(!cameraModel.isAuthorized)
                .opacity(cameraModel.isAuthorized ? 1 : 0.3)
            }
        }
    }

    private func capturePhoto() {
        cameraModel.capturePhoto { image in
            capturedImage = image
            showingPreview = true
        }
    }

    private func usePhoto() {
        if let image = capturedImage {
            onImageCaptured(image)
        }
        dismiss()
    }

    private func retake() {
        capturedImage = nil
        showingPreview = false
        cameraModel.startSession()
    }

    private func flipCamera() {
        cameraModel.flipCamera()
    }
}

// MARK: - Camera Model

@MainActor
class CameraModel: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var permissionDenied = false
    @Published var isTorchOn = false
    @Published var hasTorch = false

    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var photoCaptureCompletion: ((UIImage?) -> Void)?
    private var currentDevice: AVCaptureDevice?

    func requestPermissionAndSetup() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            isAuthorized = true
            setupCamera()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            permissionDenied = !granted
            if granted {
                setupCamera()
            }
        case .denied, .restricted:
            permissionDenied = true
            isAuthorized = false
        @unknown default:
            permissionDenied = true
            isAuthorized = false
        }
    }

    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Add camera input
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }

        // Remove existing inputs
        session.inputs.forEach { session.removeInput($0) }
        session.addInput(input)

        // Track current device for torch
        currentDevice = camera
        hasTorch = camera.hasTorch

        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        startSession()
    }

    func startSession() {
        guard !session.isRunning else { return }
        // Capture session reference before dispatching to avoid actor isolation warning
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        // Capture session reference before dispatching to avoid actor isolation warning
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.stopRunning()
        }
    }

    func flipCamera() {
        // Turn off torch before flipping
        if isTorchOn {
            toggleTorch()
        }

        currentCameraPosition = currentCameraPosition == .back ? .front : .back

        session.beginConfiguration()

        // Remove current input
        session.inputs.forEach { session.removeInput($0) }

        // Add new input
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }

        session.addInput(input)

        // Track current device for torch
        currentDevice = camera
        hasTorch = camera.hasTorch

        session.commitConfiguration()
    }

    func toggleTorch() {
        guard let device = currentDevice, device.hasTorch else { return }

        do {
            try device.lockForConfiguration()
            if isTorchOn {
                device.torchMode = .off
            } else {
                try device.setTorchModeOn(level: 1.0)
            }
            device.unlockForConfiguration()
            isTorchOn.toggle()
        } catch {
            // Torch toggle failed silently
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        photoCaptureCompletion = completion

        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor in
                photoCaptureCompletion?(nil)
            }
            return
        }

        Task { @MainActor in
            photoCaptureCompletion?(image)
        }
    }
}

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
            previewLayer.session = session
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
