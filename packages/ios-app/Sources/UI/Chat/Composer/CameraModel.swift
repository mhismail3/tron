import SwiftUI
import UIKit
@preconcurrency import AVFoundation

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
