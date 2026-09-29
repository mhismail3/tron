@preconcurrency import AVFoundation

@MainActor
package protocol CameraAuthorizationProviding {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

package struct SystemCameraAuthorizationProvider: CameraAuthorizationProviding {
    package init() {}
    package func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    package func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}
