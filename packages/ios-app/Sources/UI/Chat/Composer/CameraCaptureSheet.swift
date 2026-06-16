import SwiftUI
@preconcurrency import AVFoundation

/// Immersive camera capture sheet with the camera viewport as the primary surface.
struct CameraCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImageCaptured: (UIImage) -> Void

    @State private var cameraModel = CameraModel()
    @State private var capturedImage: UIImage?
    @State private var showingPreview = false

#if DEBUG
    private var usesDebugCameraSurface: Bool {
        ProcessInfo.processInfo.arguments.contains("--tron-debug-camera-surface")
    }
#endif

    private var shouldShowCameraStatus: Bool {
#if DEBUG
        if usesDebugCameraSurface {
            return false
        }
#endif
        return cameraModel.permissionDenied
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
            if shouldShowCameraStatus {
                cameraStatus
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .immersiveCameraSheetPresentation {
            cameraSurface
        }
        .task {
#if DEBUG
            guard !usesDebugCameraSurface else { return }
#endif
            await cameraModel.requestPermissionAndSetup()
        }
        .onDisappear {
            cameraModel.stopSession()
        }
    }

    @ViewBuilder
    private var cameraSurface: some View {
#if DEBUG
        if usesDebugCameraSurface {
            CameraDebugSurface()
        } else {
            productionCameraSurface
        }
#else
        productionCameraSurface
#endif
    }

    @ViewBuilder
    private var productionCameraSurface: some View {
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

    @ViewBuilder
    private var cameraStatus: some View {
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
            ProgressView()
                .tint(.white)
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        HStack(alignment: .center, spacing: CameraControlMetrics.captureSpacing) {
            cameraIconButton(
                systemImage: cameraModel.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                isEnabled: !showingPreview && cameraModel.isReady && cameraModel.hasTorch,
                isActive: cameraModel.isTorchOn,
                isVisible: !showingPreview,
                accessibilityLabel: "Flashlight",
                action: { cameraModel.toggleTorch() }
            )

            centerCameraButton

            cameraIconButton(
                systemImage: showingPreview ? "arrow.counterclockwise" : "arrow.triangle.2.circlepath.camera",
                isEnabled: showingPreview || cameraModel.isReady,
                accessibilityLabel: showingPreview ? "Go back to capture" : "Switch Camera",
                action: {
                    if showingPreview {
                        retake()
                    } else {
                        flipCamera()
                    }
                }
            )
        }
        .animation(CameraControlMetrics.controlAnimation, value: showingPreview)
        .animation(CameraControlMetrics.controlAnimation, value: cameraModel.isReady)
    }

    private var centerCameraButton: some View {
        Button {
            if showingPreview {
                usePhoto()
            } else {
                capturePhoto()
            }
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
        showingPreview ? capturedImage != nil : cameraModel.isReady
    }

    private var centerCameraButtonTint: Color {
        if showingPreview {
            return Color.tronEmerald.opacity(0.44)
        }
        return .white.opacity(cameraModel.isReady ? 0.44 : 0.14)
    }

    private func cameraIconButton(
        systemImage: String,
        isEnabled: Bool,
        isActive: Bool = false,
        isPrimary: Bool = false,
        isVisible: Bool = true,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                cameraGlassSurface(
                    size: isPrimary ? CameraControlMetrics.primaryIconButtonSize : CameraControlMetrics.iconButtonSize,
                    tint: (isActive ? Color.tronEmerald : Color.white).opacity(isActive ? 0.22 : 0.12),
                    isEnabled: isEnabled
                )

                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: isPrimary ? CameraControlMetrics.primaryIconFontSize : CameraControlMetrics.iconFontSize, weight: .semibold))
                    .foregroundStyle(isActive ? Color.tronEmerald : .white)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .frame(
                width: isPrimary ? CameraControlMetrics.primaryIconHitTargetSize : CameraControlMetrics.iconHitTargetSize,
                height: isPrimary ? CameraControlMetrics.primaryIconHitTargetSize : CameraControlMetrics.iconHitTargetSize
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isVisible ? (isEnabled ? 1 : 0.36) : 0)
        .scaleEffect(isVisible ? 1 : 0.82)
        .allowsHitTesting(isVisible)
        .animation(CameraControlMetrics.controlAnimation, value: isVisible)
        .animation(CameraControlMetrics.controlAnimation, value: systemImage)
        .accessibilityLabel(accessibilityLabel ?? systemImage)
        .accessibilityHidden(!isVisible)
    }

    private func cameraGlassSurface(size: CGFloat, tint: Color, isEnabled: Bool) -> some View {
        Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(tint).interactive(isEnabled), in: .circle)
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isEnabled ? 0.52 : 0.22),
                                Color.white.opacity(isEnabled ? 0.16 : 0.08),
                                Color.black.opacity(isEnabled ? 0.20 : 0.08)
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
        }
    }

    private func usePhoto() {
        if let image = capturedImage {
            onImageCaptured(image)
        }
        dismiss()
    }

    private func retake() {
        withAnimation(CameraControlMetrics.controlAnimation) {
            capturedImage = nil
            showingPreview = false
        }
        cameraModel.startSession()
    }

    private func flipCamera() {
        cameraModel.flipCamera()
    }
}

private enum CameraControlMetrics {
    static let horizontalPadding: CGFloat = 26
    static let bottomPadding: CGFloat = 48
    static let captureSpacing: CGFloat = 34
    static let iconButtonSize: CGFloat = 46
    static let primaryIconButtonSize: CGFloat = 52
    static let captureGlassSize: CGFloat = 76
    static let iconHitTargetSize: CGFloat = 60
    static let primaryIconHitTargetSize: CGFloat = 64
    static let iconFontSize: CGFloat = TronTypography.sizeTitle
    static let primaryIconFontSize: CGFloat = TronTypography.sizeLargeTitle
    static let confirmationIconFontSize: CGFloat = TronTypography.sizeLargeTitle
    static let controlAnimation = Animation.smooth(duration: 0.28)
}

// MARK: - Camera Model

@Observable
@MainActor
class CameraModel: NSObject {
    var isAuthorized = false
    var permissionDenied = false
    var cameraUnavailable = false
    var isTorchOn = false
    var hasTorch = false
    var session: AVCaptureSession?
    var isReady: Bool {
        isAuthorized && session != nil && !cameraUnavailable && !isConfiguringSession
    }

    private var photoOutput: AVCapturePhotoOutput?
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var photoCaptureCompletion: ((UIImage?) -> Void)?
    private var isConfiguringSession = false
    private let sessionQueue = DispatchQueue(label: "app.tron.camera.capture.session", qos: .userInitiated)

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
        guard !isConfiguringSession else { return }
        isConfiguringSession = true
        cameraUnavailable = false

        let existingSession = session
        let existingOutput = photoOutput
        let position = currentCameraPosition

        sessionQueue.async { [weak self] in
            let captureSession = existingSession ?? AVCaptureSession()
            let output = existingOutput ?? AVCapturePhotoOutput()
            let result = Self.configure(
                session: captureSession,
                output: output,
                position: position,
                startRunning: true
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConfiguringSession = false
                self.session = captureSession
                self.photoOutput = output
                self.hasTorch = result.hasTorch
                self.cameraUnavailable = !result.isUsable
            }
        }
    }

    private struct ConfigurationResult: Sendable {
        let didConfigure: Bool
        let hasTorch: Bool
        let isUsable: Bool
    }

    private nonisolated static func configure(
        session: AVCaptureSession,
        output: AVCapturePhotoOutput,
        position: AVCaptureDevice.Position,
        startRunning: Bool
    ) -> ConfigurationResult {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let camera = Self.cameraDevice(for: position),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            let currentInput = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first
            session.commitConfiguration()
            return ConfigurationResult(
                didConfigure: false,
                hasTorch: currentInput?.device.hasTorch ?? false,
                isUsable: currentInput != nil
            )
        }

        let previousInputs = session.inputs
        previousInputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .forEach(Self.turnOffTorchIfNeeded)
        previousInputs.forEach { session.removeInput($0) }

        guard session.canAddInput(input) else {
            previousInputs.forEach { previousInput in
                if session.canAddInput(previousInput) {
                    session.addInput(previousInput)
                }
            }
            session.commitConfiguration()
            let currentInput = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first
            return ConfigurationResult(
                didConfigure: false,
                hasTorch: currentInput?.device.hasTorch ?? false,
                isUsable: currentInput != nil
            )
        }

        session.addInput(input)

        if session.canAddOutput(output), !session.outputs.contains(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()

        if startRunning, !session.isRunning {
            session.startRunning()
        }

        return ConfigurationResult(didConfigure: true, hasTorch: camera.hasTorch, isUsable: true)
    }

    private nonisolated static func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTrueDepthCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    private nonisolated static func turnOffTorchIfNeeded(_ device: AVCaptureDevice) {
        guard device.hasTorch, device.torchMode == .on else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
        } catch {
            // Torch shutdown is best effort before camera input replacement.
        }
    }

    func startSession() {
        guard let captureSession = session else {
            setupCamera()
            return
        }
        sessionQueue.async {
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    func stopSession() {
        guard let captureSession = session else { return }
        sessionQueue.async {
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    func flipCamera() {
        let previousPosition = currentCameraPosition
        let nextPosition: AVCaptureDevice.Position = previousPosition == .back ? .front : .back

        guard !isConfiguringSession else { return }
        if isTorchOn {
            isTorchOn = false
        }
        cameraUnavailable = false
        isConfiguringSession = true

        let existingSession = session
        let existingOutput = photoOutput
        sessionQueue.async { [weak self] in
            let captureSession = existingSession ?? AVCaptureSession()
            let output = existingOutput ?? AVCapturePhotoOutput()
            let result = Self.configure(
                session: captureSession,
                output: output,
                position: nextPosition,
                startRunning: true
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConfiguringSession = false
                self.currentCameraPosition = result.didConfigure ? nextPosition : previousPosition
                self.session = captureSession
                self.photoOutput = output
                self.hasTorch = result.hasTorch
                self.cameraUnavailable = !result.isUsable
            }
        }
    }

    func toggleTorch() {
        guard !isConfiguringSession, let captureSession = session else { return }
        let shouldEnable = !isTorchOn
        sessionQueue.async { [weak self] in
            guard
                let input = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
                input.device.hasTorch
            else {
                DispatchQueue.main.async { [weak self] in
                    self?.isTorchOn = false
                    self?.hasTorch = false
                }
                return
            }

            let device = input.device
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if shouldEnable {
                    guard device.isTorchAvailable else {
                        DispatchQueue.main.async { [weak self] in
                            self?.isTorchOn = false
                            self?.hasTorch = device.hasTorch
                        }
                        return
                    }
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }

                DispatchQueue.main.async { [weak self] in
                    self?.isTorchOn = device.torchMode == .on
                    self?.hasTorch = device.hasTorch
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isTorchOn = false
                    self?.hasTorch = device.hasTorch
                }
            }
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        photoCaptureCompletion = completion

        guard let output = photoOutput else {
            completion(nil)
            return
        }
        let settings = AVCapturePhotoSettings()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            output.capturePhoto(with: settings, delegate: self)
        }
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
private struct CameraDebugSurface: View {
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
