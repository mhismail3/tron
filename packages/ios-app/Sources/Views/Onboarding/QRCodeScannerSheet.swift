import SwiftUI
@preconcurrency import AVFoundation

/// Camera sheet for scanning the Mac app's `tron://pair?...` QR code.
///
/// This intentionally mirrors the chat attachment camera sheet: a compact
/// medium detent, a square live preview, and circular glass controls.
@available(iOS 26.0, *)
struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCodeScanned: (String) -> Void

    @State private var scannerModel = QRCodeScannerModel()

    var body: some View {
        GeometryReader { geometry in
            let viewportSize = scannerViewportSize(for: geometry.size)

            VStack(spacing: 16) {
                Text("Scan Pairing Code")
                    .font(TronTypography.button)
                    .foregroundStyle(Color.tronEmerald)
                    .padding(.top, 16)

                ZStack {
                    preview(viewportSize: viewportSize)
                    scannerFrame(size: viewportSize)
                }

                Text("Point the camera at the QR code on your Mac.")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                controlButtons
                    .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .adaptivePresentationDetents([.medium], ipadSizing: .compactForm, phoneSizing: .unchanged, phoneBackground: .unchanged)
        .presentationDragIndicator(.hidden)
        .task {
            await scannerModel.requestPermissionAndSetup()
        }
        .onChange(of: scannerModel.scannedCode) { _, code in
            guard let code else { return }
            onCodeScanned(code)
            dismiss()
        }
        .onDisappear {
            scannerModel.stopSession()
        }
    }

    private func scannerViewportSize(for size: CGSize) -> CGFloat {
        let availableWidth = max(1, size.width - 56)
        let availableHeight = max(1, size.height - 190)
        let viewportSize = min(availableWidth, availableHeight)
        return viewportSize.isFinite ? viewportSize : 1
    }

    @ViewBuilder
    private func preview(viewportSize: CGFloat) -> some View {
        if scannerModel.isAuthorized {
            CameraPreviewView(session: scannerModel.session)
                .frame(width: viewportSize, height: viewportSize)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.tronSurfaceElevated)
                .frame(width: viewportSize, height: viewportSize)
                .overlay {
                    if scannerModel.permissionDenied {
                        permissionMessage(
                            title: "Camera Access Required",
                            subtitle: "Enable camera access in Settings."
                        )
                    } else if scannerModel.setupFailed {
                        permissionMessage(
                            title: "Camera Unavailable",
                            subtitle: "Enter the pairing details manually."
                        )
                    } else {
                        ProgressView()
                            .tint(Color.tronEmerald)
                    }
                }
        }
    }

    private func permissionMessage(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                .foregroundStyle(Color.tronTextMuted)
            Text(title)
                .font(TronTypography.subheadline)
                .foregroundStyle(Color.tronTextSecondary)
            Text(subtitle)
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
        }
        .multilineTextAlignment(.center)
        .padding(TronSpacing.section)
    }

    private func scannerFrame(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.tronEmerald.opacity(0.35), lineWidth: 1)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "qrcode.viewfinder")
                    .font(TronTypography.sans(size: 72, weight: .light))
                    .foregroundStyle(Color.tronEmerald.opacity(0.18))
            }
    }

    private var controlButtons: some View {
        HStack(spacing: 32) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Color.tronOverlay(0.25)).interactive(), in: Circle())

            Button {
                scannerModel.toggleTorch()
            } label: {
                Image(systemName: scannerModel.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                    .foregroundStyle(scannerModel.isTorchOn ? Color.tronEmerald : Color.tronTextPrimary)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(scannerModel.isTorchOn ? Color.tronEmerald.opacity(0.4) : Color.tronOverlay(0.25)).interactive(),
                in: Circle()
            )
            .disabled(!scannerModel.isAuthorized || !scannerModel.hasTorch)
            .opacity(scannerModel.isAuthorized && scannerModel.hasTorch ? 1 : 0.3)
        }
    }
}

@Observable
@MainActor
final class QRCodeScannerModel: NSObject {
    var isAuthorized = false
    var permissionDenied = false
    var setupFailed = false
    var isTorchOn = false
    var hasTorch = false
    var scannedCode: String?

    let session = AVCaptureSession()

    private let metadataOutput = AVCaptureMetadataOutput()
    private var currentDevice: AVCaptureDevice?
    private var didScan = false

    func requestPermissionAndSetup() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            isAuthorized = true
            setupScanner()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            permissionDenied = !granted
            if granted {
                setupScanner()
            }
        case .denied, .restricted:
            permissionDenied = true
            isAuthorized = false
        @unknown default:
            permissionDenied = true
            isAuthorized = false
        }
    }

    private func setupScanner() {
        session.beginConfiguration()
        session.sessionPreset = .high

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input),
            session.canAddOutput(metadataOutput)
        else {
            setupFailed = true
            session.commitConfiguration()
            return
        }

        currentDevice = camera
        hasTorch = camera.hasTorch
        session.addInput(input)
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            setupFailed = true
        }

        session.commitConfiguration()
        if !setupFailed {
            startSession()
        }
    }

    func startSession() {
        guard !session.isRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.stopRunning()
        }
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
            // The torch is optional; failing to toggle it should not block scanning.
        }
    }

    func acceptScannedCode(_ code: String) {
        guard !didScan else { return }
        didScan = true
        scannedCode = code
        stopSession()
    }
}

extension QRCodeScannerModel: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let qrObject = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr }),
            let code = qrObject.stringValue
        else {
            return
        }

        Task { @MainActor in
            self.acceptScannedCode(code)
        }
    }
}
