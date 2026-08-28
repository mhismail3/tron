import SwiftUI
import UIKit
@preconcurrency import AVFoundation

private final class CameraPhotoDelegateProxy: NSObject, AVCapturePhotoCaptureDelegate {
    weak var model: CameraModel?
    let generation: Int

    init(model: CameraModel, generation: Int) {
        self.model = model
        self.generation = generation
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        let generation = self.generation
        Task { @MainActor [weak model] in
            model?.finishCapture(generation: generation, image: image)
        }
    }
}

@Observable
@MainActor
final class CameraModel: NSObject {
    var isAuthorized = false
    var permissionDenied = false
    var cameraUnavailable = false
    var isTorchOn = false
    var hasTorch = false
    var isCapturing = false
    var session: AVCaptureSession?
    var isReady: Bool {
        isAuthorized && !permissionDenied && session != nil && !cameraUnavailable && !configuring
    }

    private var photoOutput: AVCapturePhotoOutput?
    private var position: AVCaptureDevice.Position = .back
    private var completion: ((UIImage?) -> Void)?
    private var captureDelegate: CameraPhotoDelegateProxy?
    private var captureGeneration = 0
    private var lifecycleGeneration = 0
    private var configurationGeneration = 0
    private var configuring = false
    private let authorization: any CameraAuthorizationProviding
    private let sessions: any CameraSessionProviding

    init(
        authorization: any CameraAuthorizationProviding = SystemCameraAuthorizationProvider(),
        sessions: any CameraSessionProviding = SystemCameraSessionProvider()
    ) {
        self.authorization = authorization
        self.sessions = sessions
    }

    func requestPermissionAndSetup() async {
        let lifecycle = lifecycleGeneration
        do {
            try Task.checkCancellation()
            switch authorization.authorizationStatus() {
            case .authorized:
                try Task.checkCancellation()
                guard lifecycle == lifecycleGeneration else { return }
                isAuthorized = true
                permissionDenied = false
                setup()
            case .notDetermined:
                let granted = await authorization.requestAccess()
                try Task.checkCancellation()
                guard lifecycle == lifecycleGeneration else { return }
                isAuthorized = granted
                permissionDenied = !granted
                if granted { setup() }
            case .denied, .restricted:
                try Task.checkCancellation()
                guard lifecycle == lifecycleGeneration else { return }
                isAuthorized = false
                permissionDenied = true
            @unknown default:
                try Task.checkCancellation()
                guard lifecycle == lifecycleGeneration else { return }
                isAuthorized = false
                permissionDenied = true
            }
        } catch is CancellationError {
            // A dismissed sheet must not surface task cancellation as a camera
            // failure or publish a partial permission state.
            return
        } catch {
            return
        }
    }

    private func setup() {
        guard !Task.isCancelled, !configuring else { return }
        configuring = true
        configurationGeneration &+= 1
        let generation = configurationGeneration
        let lifecycle = lifecycleGeneration
        let requestedPosition = position
        sessions.configure(position: requestedPosition) { [weak self] configuration in
            guard let self,
                  !Task.isCancelled,
                  lifecycle == self.lifecycleGeneration,
                  generation == self.configurationGeneration,
                  requestedPosition == self.position else { return }
            configuring = false
            guard let configuration else {
                cameraUnavailable = true
                return
            }
            session = configuration.session
            photoOutput = configuration.photoOutput
            hasTorch = configuration.hasTorch
            cameraUnavailable = false
            // Configuration is admitted above against every lifecycle and
            // position generation before the session is allowed to run.
            sessions.start(configuration.session)
        }
    }

    func stopSession() {
        // Sheet dismissal is also capture cancellation. Invalidate both
        // callbacks before invoking client code to make reentrancy harmless.
        lifecycleGeneration &+= 1
        configurationGeneration &+= 1
        configuring = false
        cancelCapture()
        if let session { sessions.stop(session) }
    }

    func startSession() {
        guard let session else { setup(); return }
        sessions.start(session)
    }

    func flipCamera() {
        guard !isCapturing else { return }
        configurationGeneration &+= 1
        configuring = false
        stopSession()
        session = nil
        photoOutput = nil
        isTorchOn = false
        position = position == .back ? .front : .back
        setup()
    }

    func toggleTorch() {
        guard !isCapturing, let session else { return }
        let lifecycle = lifecycleGeneration
        sessions.setTorch(on: !isTorchOn, session: session) { [weak self] enabled in
            guard let self,
                  lifecycle == self.lifecycleGeneration,
                  !self.isCapturing else { return }
            self.isTorchOn = enabled
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        guard !isCapturing else { return }
        captureGeneration &+= 1
        let generation = captureGeneration
        isCapturing = true
        self.completion = completion
        guard let photoOutput else { finishCapture(generation: generation, image: nil); return }
        let delegate = CameraPhotoDelegateProxy(model: self, generation: generation)
        captureDelegate = delegate
        sessions.capturePhoto(
            CameraPhotoCaptureRequest(
                output: photoOutput,
                settings: AVCapturePhotoSettings(),
                delegate: delegate
            )
        )
    }

    func cancelCapture() {
        guard isCapturing else { return }
        captureGeneration &+= 1
        settleCapture(image: nil)
    }

    fileprivate func finishCapture(generation: Int, image: UIImage?) {
        guard isCapturing, generation == captureGeneration else { return }
        settleCapture(image: image)
    }

    private func settleCapture(image: UIImage?) {
        let callback = completion
        completion = nil
        captureDelegate = nil
        isCapturing = false
        // Clear ownership before invoking client code so a callback can safely
        // start the next capture without replacing this callback.
        callback?(image)
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

/// Immersive camera capture restored from the pre-gateway app: the live camera
/// owns the full sheet while flashlight, shutter/confirm, and flip/retake keep
/// one stable morphing control row.
struct CameraCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImageCaptured: (UIImage) -> Void

    @State private var cameraModel = CameraModel()
    @State private var capturedImage: UIImage?
    @State private var showingPreview = false

    private var shouldShowCameraStatus: Bool {
        cameraModel.permissionDenied
            || cameraModel.cameraUnavailable
            || !cameraModel.isAuthorized
            || (!showingPreview && cameraModel.session == nil)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                controlButtons
                    .padding(.horizontal, CameraControlMetrics.horizontalPadding)
                    .padding(.bottom, CameraControlMetrics.bottomPadding + proxy.safeAreaInsets.bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if shouldShowCameraStatus { cameraStatus }
        }
        .ignoresSafeArea(.container, edges: .all)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .task { await cameraModel.requestPermissionAndSetup() }
        .onDisappear { cameraModel.stopSession() }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .presentationBackground(alignment: .center) {
            cameraSurface
                .ignoresSafeArea(.container, edges: .all)
        }
    }

    @ViewBuilder private var cameraSurface: some View {
        if let image = capturedImage, showingPreview {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if cameraModel.isAuthorized, let session = cameraModel.session {
            CameraPreviewView(session: session)
        } else {
            Color.black
        }
    }

    @ViewBuilder private var cameraStatus: some View {
        if cameraModel.permissionDenied || cameraModel.cameraUnavailable {
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                    .foregroundStyle(.white.opacity(0.45))
                Text(cameraModel.permissionDenied ? "Camera Access Required" : "Camera Unavailable")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                Text(cameraModel.permissionDenied ? "Enable in Settings" : "Try again later")
                    .font(TronTypography.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        } else {
            TronPulseLoadingIndicator(accent: .white, size: 20)
        }
    }

    private var controlButtons: some View {
        HStack(alignment: .center, spacing: CameraControlMetrics.captureSpacing) {
            cameraIconButton(
                systemImage: cameraModel.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                isEnabled: !showingPreview && cameraModel.isReady && cameraModel.hasTorch && !cameraModel.isCapturing,
                isActive: cameraModel.isTorchOn,
                isVisible: !showingPreview,
                accessibilityLabel: "Flashlight",
                action: { cameraModel.toggleTorch() }
            )

            centerCameraButton

            cameraIconButton(
                systemImage: showingPreview ? "arrow.counterclockwise" : "arrow.triangle.2.circlepath.camera",
                isEnabled: showingPreview || (cameraModel.isReady && !cameraModel.isCapturing),
                accessibilityLabel: showingPreview ? "Go back to capture" : "Switch Camera",
                action: {
                    if showingPreview { retake() }
                    else { cameraModel.flipCamera() }
                }
            )
        }
        .animation(CameraControlMetrics.controlAnimation, value: showingPreview)
        .animation(CameraControlMetrics.controlAnimation, value: cameraModel.isReady)
    }

    private var centerCameraButton: some View {
        Button {
            if showingPreview { usePhoto() }
            else { capturePhoto() }
        } label: {
            ZStack {
                cameraGlassSurface(
                    size: CameraControlMetrics.captureGlassSize,
                    tint: centerCameraButtonTint,
                    isEnabled: centerCameraButtonIsEnabled
                )

                if showingPreview {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: CameraControlMetrics.confirmationIconFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
            }
            .frame(width: CameraControlMetrics.captureGlassSize, height: CameraControlMetrics.captureGlassSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!centerCameraButtonIsEnabled)
        .accessibilityLabel(showingPreview ? "Use photo" : "Capture photo")
        .animation(CameraControlMetrics.controlAnimation, value: showingPreview)
    }

    private var centerCameraButtonIsEnabled: Bool {
        showingPreview ? capturedImage != nil : cameraModel.isReady && !cameraModel.isCapturing
    }

    private var centerCameraButtonTint: Color {
        if showingPreview { return Color.tronEmerald.opacity(0.44) }
        return .white.opacity(cameraModel.isReady && !cameraModel.isCapturing ? 0.44 : 0.14)
    }

    private func cameraIconButton(
        systemImage: String,
        isEnabled: Bool,
        isActive: Bool = false,
        isVisible: Bool = true,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                cameraGlassSurface(
                    size: CameraControlMetrics.iconButtonSize,
                    tint: (isActive ? Color.tronEmerald : Color.white).opacity(isActive ? 0.22 : 0.12),
                    isEnabled: isEnabled
                )
                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: CameraControlMetrics.iconFontSize, weight: .semibold))
                    .foregroundStyle(isActive ? Color.tronEmerald : .white)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .frame(width: CameraControlMetrics.iconHitTargetSize, height: CameraControlMetrics.iconHitTargetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isVisible ? (isEnabled ? 1 : 0.36) : 0)
        .scaleEffect(isVisible ? 1 : 0.82)
        .allowsHitTesting(isVisible)
        .animation(CameraControlMetrics.controlAnimation, value: isVisible)
        .animation(CameraControlMetrics.controlAnimation, value: systemImage)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(!isVisible)
    }

    private func cameraGlassSurface(size: CGFloat, tint: Color, isEnabled: Bool) -> some View {
        Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(tint).interactive(isEnabled), in: .circle)
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isEnabled ? 0.52 : 0.22),
                            Color.white.opacity(isEnabled ? 0.16 : 0.08),
                            Color.black.opacity(isEnabled ? 0.20 : 0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }

    private func capturePhoto() {
        cameraModel.capturePhoto { image in
            guard let image else { return }
            withAnimation(CameraControlMetrics.controlAnimation) {
                capturedImage = image
                showingPreview = true
            }
            cameraModel.stopSession()
        }
    }

    private func usePhoto() {
        guard let capturedImage else { return }
        onImageCaptured(capturedImage)
        dismiss()
    }

    private func retake() {
        withAnimation(CameraControlMetrics.controlAnimation) {
            capturedImage = nil
            showingPreview = false
        }
        cameraModel.startSession()
    }
}

@MainActor
private enum CameraControlMetrics {
    static let horizontalPadding: CGFloat = 26
    static let bottomPadding: CGFloat = 48
    static let captureSpacing: CGFloat = 34
    static let iconButtonSize: CGFloat = 46
    static let captureGlassSize: CGFloat = 76
    static let iconHitTargetSize: CGFloat = 60
    static let iconFontSize: CGFloat = TronTypography.sizeTitle
    static let confirmationIconFontSize: CGFloat = TronTypography.sizeLargeTitle
    static let controlAnimation = Animation.smooth(duration: 0.28)
}
