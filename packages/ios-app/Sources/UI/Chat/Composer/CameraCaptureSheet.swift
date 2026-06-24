import SwiftUI
import UIKit

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
