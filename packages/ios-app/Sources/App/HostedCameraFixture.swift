#if HOSTED_TEST
@preconcurrency import AVFoundation
import TronMobileCore
import UIKit

/// Scripted camera hardware for the hosted camera journey (#937). With
/// `-tron-camera-fixture`, the real camera sheet and `CameraModel` run against
/// a granted permission and a provider whose feed becomes live after
/// `-camera-fixture-latency-ms` (default 800), like a camera warming up; the
/// first start may be slower (`-camera-fixture-start-latency-ms`) so a journey
/// can observe the opening state. Its
/// frames are solid colours: the back camera red (with a torch), the front
/// camera blue (without one). The preview layer itself stays black.
enum HostedCameraFixture {
    @MainActor static func model() -> CameraModel? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-tron-camera-fixture") else { return nil }
        func milliseconds(_ name: String) -> Int? {
            arguments.drop(while: { $0 != name }).dropFirst().first.flatMap(Int.init)
        }
        let latency = milliseconds("-camera-fixture-latency-ms") ?? 800
        let startLatency = milliseconds("-camera-fixture-start-latency-ms") ?? latency
        return CameraModel(
            authorization: HostedCameraAuthorization(),
            sessions: HostedCameraSessionProvider(startLatency: .milliseconds(startLatency), latency: .milliseconds(latency))
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
    private let startLatency: Duration
    private let latency: Duration
    private var position: AVCaptureDevice.Position = .back
    private var pending: Task<Void, Never>?

    init(startLatency: Duration, latency: Duration) {
        self.startLatency = startLatency
        self.latency = latency
    }

    func start(position: AVCaptureDevice.Position, token: Int) {
        self.position = position
        goLive(token: token, after: startLatency)
    }

    func switchCamera(to position: AVCaptureDevice.Position, token: Int) {
        onEvent?(token, .frozenFrame(Self.frame(for: self.position)))
        self.position = position
        goLive(token: token, after: latency)
    }

    func pause() { pending?.cancel() }
    func resume(token: Int) { goLive(token: token, after: latency) }

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

    private func goLive(token: Int, after latency: Duration) {
        pending?.cancel()
        let position = position
        pending = Task { [weak self] in
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
