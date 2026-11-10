@preconcurrency import AVFoundation
import CoreImage
import UIKit

struct CameraDevice: Equatable, Sendable {
    let position: AVCaptureDevice.Position
    let hasTorch: Bool
}

enum CameraSessionEvent: @unchecked Sendable {
    case frozenFrame(UIImage)
    case live(CameraDevice)
    case unavailable
    case switchFailed
}

@MainActor
protocol CameraSessionProviding: AnyObject {
    var session: AVCaptureSession { get }
    var onEvent: (@MainActor (Int, CameraSessionEvent) -> Void)? { get set }
    func start(position: AVCaptureDevice.Position, token: Int)
    func switchCamera(to position: AVCaptureDevice.Position, token: Int)
    func pause()
    func resume(token: Int)
    func stop()
    func setTorch(on: Bool, completion: @escaping @MainActor (Bool) -> Void)
    func capturePhoto(completion: @escaping @MainActor (UIImage?) -> Void)
}

@MainActor
final class SystemCameraSessionProvider: CameraSessionProviding {
    var onEvent: (@MainActor (Int, CameraSessionEvent) -> Void)?
    private lazy var graph: CameraCaptureGraph = {
        let graph = CameraCaptureGraph()
        graph.setEmitter { [weak self] token, event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onEvent?(token, event) }
            }
        }
        return graph
    }()

    var session: AVCaptureSession { graph.session }

    func start(position: AVCaptureDevice.Position, token: Int) { graph.start(position: position, token: token) }
    func switchCamera(to position: AVCaptureDevice.Position, token: Int) { graph.switchCamera(to: position, token: token) }
    func pause() { graph.pause() }
    func resume(token: Int) { graph.resume(token: token) }

    func stop() {
        onEvent = nil
        graph.stop()
    }

    func setTorch(on: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        graph.setTorch(on: on) { enabled in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(enabled) } }
        }
    }

    func capturePhoto(completion: @escaping @MainActor (UIImage?) -> Void) {
        graph.capturePhoto { image in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
    }
}

private final class CameraCaptureGraph: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "app.tron.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "app.tron.camera.frames", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private let frameOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var wantsRunning = false
    private var stopped = false
    private var photoDelegates: [Int64: CameraPhotoDelegate] = [:]
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])

    private let lock = NSLock()
    private var latestFrame: CMSampleBuffer?
    private var awaiting: (token: Int, input: AVCaptureInput, device: CameraDevice)?
    private var emitter: (@Sendable (Int, CameraSessionEvent) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(runtimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    func setEmitter(_ emitter: @escaping @Sendable (Int, CameraSessionEvent) -> Void) {
        lock.withLock { self.emitter = emitter }
    }

    private func emit(_ token: Int, _ event: CameraSessionEvent) {
        lock.withLock { emitter }?(token, event)
    }

    func start(position: AVCaptureDevice.Position, token: Int) {
        sessionQueue.async { [self] in
            guard !stopped else { return }
            if input == nil {
                guard let device = Self.camera(at: position),
                      let newInput = try? AVCaptureDeviceInput(device: device) else {
                    emit(token, .unavailable); return
                }
                session.beginConfiguration()
                session.sessionPreset = .photo
                frameOutput.alwaysDiscardsLateVideoFrames = true
                frameOutput.setSampleBufferDelegate(self, queue: frameQueue)
                guard session.canAddInput(newInput), session.canAddOutput(photoOutput),
                      session.canAddOutput(frameOutput) else {
                    session.commitConfiguration()
                    emit(token, .unavailable); return
                }
                session.addInput(newInput)
                session.addOutput(photoOutput)
                session.addOutput(frameOutput)
                input = newInput
                arm(token, newInput)
                session.commitConfiguration()
            } else if let input {
                arm(token, input)
            }
            run()
        }
    }

    func switchCamera(to position: AVCaptureDevice.Position, token: Int) {
        sessionQueue.async { [self] in
            guard !stopped, let current = input else { emit(token, .switchFailed); return }
            if let frame = lock.withLock({ latestFrame }),
               let image = snapshot(frame, mirrored: current.device.position == .front) {
                emit(token, .frozenFrame(image))
            }
            guard let device = Self.camera(at: position),
                  let next = try? AVCaptureDeviceInput(device: device) else {
                emit(token, .switchFailed); return
            }
            Self.setTorch(false, on: current.device)
            session.beginConfiguration()
            session.removeInput(current)
            guard session.canAddInput(next) else {
                session.addInput(current)
                session.commitConfiguration()
                emit(token, .switchFailed); return
            }
            session.addInput(next)
            input = next
            arm(token, next)
            session.commitConfiguration()
            run()
        }
    }

    func pause() {
        sessionQueue.async { [self] in
            wantsRunning = false
            lock.withLock { latestFrame = nil; awaiting = nil }
            if session.isRunning { session.stopRunning() }
        }
    }

    func resume(token: Int) {
        sessionQueue.async { [self] in
            guard !stopped, let input else { return }
            arm(token, input)
            run()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            stopped = true
            wantsRunning = false
            lock.withLock { latestFrame = nil; awaiting = nil; emitter = nil }
            frameOutput.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
            NotificationCenter.default.removeObserver(self)
        }
    }

    func setTorch(on: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [self] in
            guard let device = input?.device, !stopped else { completion(false); return }
            completion(Self.setTorch(on, on: device))
        }
    }

    func capturePhoto(completion: @escaping @Sendable (UIImage?) -> Void) {
        sessionQueue.async { [self] in
            guard !stopped, session.isRunning, !photoOutput.connections.isEmpty else { completion(nil); return }
            let settings = AVCapturePhotoSettings()
            let id = settings.uniqueID
            let delegate = CameraPhotoDelegate { [weak self] image in
                self?.sessionQueue.async { self?.photoDelegates[id] = nil }
                completion(image)
            }
            photoDelegates[id] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func arm(_ token: Int, _ input: AVCaptureDeviceInput) {
        let device = CameraDevice(position: input.device.position, hasTorch: input.device.hasTorch)
        lock.withLock { awaiting = (token, input, device) }
    }

    private func run() {
        wantsRunning = true
        if !session.isRunning { session.startRunning() }
    }

    @objc private func runtimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        guard error?.code == .mediaServicesWereReset else { return }
        sessionQueue.async { [self] in
            if wantsRunning, !stopped, !session.isRunning { session.startRunning() }
        }
    }

    private func snapshot(_ frame: CMSampleBuffer, mirrored: Bool) -> UIImage? {
        guard let pixels = CMSampleBufferGetImageBuffer(frame) else { return nil }
        var image = CIImage(cvPixelBuffer: pixels).oriented(mirrored ? .leftMirrored : .right)
        let longest = max(image.extent.width, image.extent.height)
        if longest > 720 {
            let scale = 720 / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: position
        ).devices.first
    }

    @discardableResult
    private static func setTorch(_ on: Bool, on device: AVCaptureDevice) -> Bool {
        guard device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on { try device.setTorchModeOn(level: 1) } else { device.torchMode = .off }
            return device.torchMode == .on
        } catch {
            return false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let arrived: (token: Int, device: CameraDevice)? = lock.withLock {
            latestFrame = sampleBuffer
            guard let awaiting, connection.inputPorts.contains(where: { $0.input === awaiting.input }) else { return nil }
            self.awaiting = nil
            return (awaiting.token, awaiting.device)
        }
        if let arrived { emit(arrived.token, .live(arrived.device)) }
    }
}

private final class CameraPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (UIImage?) -> Void

    init(completion: @escaping @Sendable (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        completion(error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil)
    }
}
