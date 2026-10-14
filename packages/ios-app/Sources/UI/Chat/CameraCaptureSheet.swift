import SwiftUI
import UIKit
import TronMobileCore
@preconcurrency import AVFoundation

/// The camera sheet's feed state (#937). Only `starting` shows the shared
/// sheet loading pulse: switching cameras and retaking hold the last frame,
/// blurred, over the still-mounted preview until the next feed is live.
enum CameraFeedPhase: String, Sendable {
    case starting, live, switching, captured, resuming, denied, unavailable
}

@Observable
@MainActor
final class CameraModel {
    private(set) var phase: CameraFeedPhase = .starting
    private(set) var device: CameraDevice?
    private(set) var isTorchOn = false
    private(set) var isCapturing = false
    /// The captured photo, shown sharp while `captured`.
    private(set) var capturedImage: UIImage?
    /// The outgoing camera's last frame, or the discarded photo on retake.
    private(set) var frozenFrame: UIImage?
    #if HOSTED_TEST
    private(set) var phaseHistory: [CameraFeedPhase] = [.starting]
    #endif

    var session: AVCaptureSession { sessions.session }
    var hasTorch: Bool { device?.hasTorch ?? false }
    var showsLoading: Bool { phase == .starting }
    var showsFeed: Bool { phase != .denied && phase != .unavailable }
    var canCapture: Bool { phase == .live && !isCapturing }
    /// Controls keep their enabled look through a switch or retake so the row
    /// does not dim and brighten; the model ignores taps until the feed is live.
    var controlsLookEnabled: Bool {
        [.live, .switching, .resuming].contains(phase) && !isCapturing
    }

    private var position: AVCaptureDevice.Position = .back
    private var token = 0
    private var captureToken = 0
    private var active = true
    private let authorization: any CameraAuthorizationProviding
    private let sessions: any CameraSessionProviding

    init(
        authorization: any CameraAuthorizationProviding = SystemCameraAuthorizationProvider(),
        sessions: any CameraSessionProviding = SystemCameraSessionProvider()
    ) {
        self.authorization = authorization
        self.sessions = sessions
    }

    /// The process's camera model: the hosted UI fixture substitutes scripted
    /// camera hardware; every other build uses the system camera.
    static func forCurrentProcess() -> CameraModel {
        #if HOSTED_TEST
        if let hosted = HostedCameraFixture.model() { return hosted }
        #endif
        return CameraModel()
    }

    func requestPermissionAndSetup() async {
        switch authorization.authorizationStatus() {
        case .authorized:
            start()
        case .notDetermined:
            let granted = await authorization.requestAccess()
            // A dismissed sheet must not publish a partial permission state.
            guard active, !Task.isCancelled else { return }
            if granted { start() } else { transition(to: .denied) }
        case .denied, .restricted:
            transition(to: .denied)
        @unknown default:
            transition(to: .denied)
        }
    }

    private func start() {
        guard active, phase == .starting else { return }
        sessions.onEvent = { [weak self] token, event in self?.handle(token, event) }
        token &+= 1
        sessions.start(position: position, token: token)
    }

    /// Sheet dismissal: ends the session and cancels an in-flight capture.
    func stopSession() {
        active = false
        isCapturing = false
        captureToken &+= 1
        sessions.stop()
    }

    func flipCamera() {
        guard active, phase == .live, !isCapturing else { return }
        isTorchOn = false
        transition(to: .switching)
        token &+= 1
        sessions.switchCamera(to: position == .back ? .front : .back, token: token)
    }

    func toggleTorch() {
        guard active, phase == .live, !isCapturing, hasTorch else { return }
        let token = token
        sessions.setTorch(on: !isTorchOn) { [weak self] enabled in
            guard let self, active, token == self.token, phase == .live else { return }
            isTorchOn = enabled
        }
    }

    func capturePhoto() {
        guard active, canCapture else { return }
        captureToken &+= 1
        let captureToken = captureToken
        isCapturing = true
        sessions.capturePhoto { [weak self] image in
            guard let self, active, isCapturing, captureToken == self.captureToken else { return }
            isCapturing = false
            // A failed capture keeps the live feed, as before.
            guard let image else { return }
            capturedImage = image
            isTorchOn = false
            transition(to: .captured)
            sessions.pause()
        }
    }

    func retake() {
        guard active, phase == .captured else { return }
        // The discarded photo stays on screen, blurred, until the feed is back.
        frozenFrame = capturedImage
        capturedImage = nil
        transition(to: .resuming)
        token &+= 1
        sessions.resume(token: token)
    }

    private func handle(_ eventToken: Int, _ event: CameraSessionEvent) {
        guard active, eventToken == token else { return }
        switch event {
        case .frozenFrame(let image):
            if phase == .switching { frozenFrame = image }
        case .live(let device):
            self.device = device
            position = device.position
            frozenFrame = nil
            transition(to: .live)
        case .unavailable:
            transition(to: .unavailable)
        case .switchFailed:
            frozenFrame = nil
            transition(to: .live)
        }
    }

    private func transition(to next: CameraFeedPhase) {
        guard next != phase else { return }
        phase = next
        #if HOSTED_TEST
        phaseHistory.append(next)
        #endif
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
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { nil }
}

/// Immersive camera capture restored from the pre-gateway app: the live camera
/// owns the full sheet while flashlight, shutter/confirm, and flip/retake keep
/// one stable morphing control row. The preview layer stays mounted for the
/// sheet's life; switches and retakes cross-fade from a blurred still (#937).
struct CameraCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onImageCaptured: (UIImage) -> Void

    @State private var cameraModel = CameraModel.forCurrentProcess()

    private var showingPreview: Bool { cameraModel.phase == .captured }

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
        .overlay { cameraStatus }
        #if HOSTED_TEST
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(cameraModel.phaseHistory.map(\.rawValue).joined(separator: ">"))
                .accessibilityIdentifier("camera.phase-history")
        }
        #endif
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

    /// Black, then the one preview layer, then the held still. Only the still
    /// and the preview's opacity change between phases; nothing is remounted.
    private var cameraSurface: some View {
        ZStack {
            Color.black
            if cameraModel.showsFeed {
                CameraPreviewView(session: cameraModel.session)
                    .opacity(cameraModel.showsLoading ? 0 : 1)
            }
            if let still = cameraModel.capturedImage ?? cameraModel.frozenFrame {
                // One identity for the captured photo and the frozen frame, so a
                // retake animates the same image from sharp to blurred.
                Image(uiImage: still)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: showingPreview ? 0 : CameraControlMetrics.stillBlurRadius, opaque: true)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(CameraControlMetrics.feedAnimation(reduceMotion: reduceMotion), value: cameraModel.phase)
        .animation(CameraControlMetrics.feedAnimation(reduceMotion: reduceMotion), value: cameraModel.frozenFrame != nil)
    }

    @ViewBuilder private var cameraStatus: some View {
        switch cameraModel.phase {
        case .denied, .unavailable:
            let denied = cameraModel.phase == .denied
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                    .foregroundStyle(.white.opacity(0.45))
                Text(denied ? "Camera Access Required" : "Camera Unavailable")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                Text(denied ? "Enable in Settings" : "Try again later")
                    .font(TronTypography.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        case .starting:
            // The shared sheet loading state; when #890's surface-hosted
            // `TronSheetLoadingState` lands this call site becomes that type.
            TronLoadingState(label: "Opening camera")
                .accessibilityIdentifier("sheet-loading")
                .transition(.opacity)
        case .live, .switching, .captured, .resuming:
            EmptyView()
        }
    }

    private var controlButtons: some View {
        HStack(alignment: .center, spacing: CameraControlMetrics.captureSpacing) {
            cameraIconButton(
                systemImage: cameraModel.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                // Follows the camera actually feeding the preview: a switch to a
                // camera without a torch disables it until that feed is live.
                isEnabled: cameraModel.phase == .live && cameraModel.hasTorch && !cameraModel.isCapturing,
                isActive: cameraModel.isTorchOn,
                isVisible: !showingPreview,
                accessibilityLabel: "Flashlight",
                action: { cameraModel.toggleTorch() }
            )

            centerCameraButton

            cameraIconButton(
                systemImage: showingPreview ? "arrow.counterclockwise" : "arrow.triangle.2.circlepath.camera",
                isEnabled: showingPreview || cameraModel.controlsLookEnabled,
                accessibilityLabel: showingPreview ? "Go back to capture" : "Switch Camera",
                action: {
                    if showingPreview { retake() }
                    else { cameraModel.flipCamera() }
                }
            )
        }
        .animation(CameraControlMetrics.controlAnimation, value: cameraModel.phase)
    }

    private var centerCameraButton: some View {
        Button {
            if showingPreview { usePhoto() }
            else { cameraModel.capturePhoto() }
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
        showingPreview ? cameraModel.capturedImage != nil : cameraModel.controlsLookEnabled
    }

    private var centerCameraButtonTint: Color {
        if showingPreview { return Color.tronEmerald.opacity(0.44) }
        return .white.opacity(cameraModel.controlsLookEnabled ? 0.44 : 0.14)
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

    private func usePhoto() {
        guard let capturedImage = cameraModel.capturedImage else { return }
        onImageCaptured(capturedImage)
        dismiss()
    }

    private func retake() {
        withAnimation(CameraControlMetrics.controlAnimation) { cameraModel.retake() }
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
    static let controlAnimation = ChatMotion.cameraControl
    static let stillBlurRadius: CGFloat = 24

    static func feedAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : controlAnimation
    }
}
