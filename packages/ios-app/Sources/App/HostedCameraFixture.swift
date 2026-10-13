#if HOSTED_TEST
@preconcurrency import AVFoundation
import TronMobileCore
import UIKit

/// Scripted camera hardware for the hosted camera journey (#937). With
/// `-tron-camera-fixture`, the real camera sheet and `CameraModel` run against
/// a granted permission and a provider whose feed becomes live after
/// `-camera-fixture-latency-ms` (default 800), like a camera warming up. Its
/// frames are solid colours: the back camera red (with a torch), the front
/// camera blue (without one). The preview layer itself stays black.
enum HostedCameraFixture {
    @MainActor static func model() -> CameraModel? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-tron-camera-fixture") else { return nil }
        let latency = arguments.drop(while: { $0 != "-camera-fixture-latency-ms" }).dropFirst().first.flatMap(Int.init) ?? 800
        return CameraModel(
            authorization: HostedCameraAuthorization(),
            sessions: HostedCameraSessionProvider(latency: .milliseconds(latency))
        )
    }
}

private struct HostedCameraAuthorization: CameraAuthorizationProviding {
    func authorizationStatus() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

@MainActor
private final class HostedCameraSessionProvider: CameraSessionProviding {
    var onEvent: (@MainActor (Int, CameraSessionEvent) -> Void)?
    private(set) lazy var session = AVCaptureSession()
    private let latency: Duration
    private var position: AVCaptureDevice.Position = .back
    private var pending: Task<Void, Never>?

    init(latency: Duration) { self.latency = latency }

    func start(position: AVCaptureDevice.Position, token: Int) {
        self.position = position
        goLive(token: token)
    }

    func switchCamera(to position: AVCaptureDevice.Position, token: Int) {
        onEvent?(token, .frozenFrame(Self.frame(for: self.position)))
        self.position = position
        goLive(token: token)
    }

    func pause() { pending?.cancel() }
    func resume(token: Int) { goLive(token: token) }

    func stop() {
        pending?.cancel()
        onEvent = nil
    }

    func setTorch(on: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        completion(on && position == .back)
    }

    func capturePhoto(completion: @escaping @MainActor (UIImage?) -> Void) {
        completion(Self.frame(for: position))
    }

    private func goLive(token: Int) {
        pending?.cancel()
        let position = position
        pending = Task { [weak self, latency] in
            try? await Task.sleep(for: latency)
            guard !Task.isCancelled else { return }
            self?.onEvent?(token, .live(CameraDevice(position: position, hasTorch: position == .back)))
        }
    }

    private static func frame(for position: AVCaptureDevice.Position) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 90, height: 160), format: format).image { context in
            (position == .back ? UIColor.systemRed : UIColor.systemBlue).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
        }
    }
}
#endif
