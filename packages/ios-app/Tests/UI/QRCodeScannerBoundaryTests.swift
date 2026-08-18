@preconcurrency import AVFoundation
import Testing
@testable import TronMobile

@MainActor
@Suite("QR scanner system-service boundaries")
struct QRCodeScannerBoundaryTests {
    @Test("authorized scanner configures and starts once")
    func authorizedStart() async {
        let authorization = QRRecordingAuthorization(status: .authorized)
        let capture = QRRecordingCapture()
        let controller = ScannerController(authorization: authorization, capture: capture)

        controller.loadViewIfNeeded()
        await settle()

        #expect(authorization.requestCount == 0)
        #expect(capture.configureCount == 1)
        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 0)
    }

    @Test("undetermined permission starts only after a grant", arguments: [true, false])
    func permissionRequest(granted: Bool) async {
        let authorization = QRRecordingAuthorization(status: .notDetermined, granted: granted)
        let capture = QRRecordingCapture()
        let controller = ScannerController(authorization: authorization, capture: capture)

        controller.loadViewIfNeeded()
        await settle()

        #expect(authorization.requestCount == 1)
        #expect(capture.configureCount == (granted ? 1 : 0))
        #expect(capture.startCount == (granted ? 1 : 0))
    }

    @Test("denied scanner never configures capture")
    func denied() async {
        let capture = QRRecordingCapture()
        let controller = ScannerController(
            authorization: QRRecordingAuthorization(status: .denied),
            capture: capture
        )

        controller.loadViewIfNeeded()
        await settle()

        #expect(capture.configureCount == 0)
        #expect(capture.startCount == 0)
    }

    @Test("the first QR value stops capture and later values are ignored")
    func oneAdmission() async {
        let capture = QRRecordingCapture()
        let controller = ScannerController(
            authorization: QRRecordingAuthorization(status: .authorized),
            capture: capture
        )
        var values: [String] = []
        controller.onCode = { values.append($0) }
        controller.loadViewIfNeeded()
        await settle()

        controller.admit("first")
        controller.admit("second")

        #expect(values == ["first"])
        #expect(capture.stopCount == 1)
    }

    @Test("disappearance cancels a pending permission result before capture starts")
    func cancelledPermission() async {
        let authorization = QRControlledAuthorization()
        let capture = QRRecordingCapture()
        let controller = ScannerController(authorization: authorization, capture: capture)
        controller.loadViewIfNeeded()
        while authorization.requestCount == 0 { await Task.yield() }

        controller.viewDidDisappear(false)
        authorization.resolve(true)
        await settle()

        #expect(capture.stopCount == 1)
        #expect(capture.configureCount == 0)
        #expect(capture.startCount == 0)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class QRRecordingAuthorization: CameraAuthorizationProviding {
    let status: AVAuthorizationStatus
    let granted: Bool
    private(set) var requestCount = 0

    init(status: AVAuthorizationStatus, granted: Bool = false) {
        self.status = status
        self.granted = granted
    }

    func authorizationStatus() -> AVAuthorizationStatus { status }

    func requestAccess() async -> Bool {
        requestCount += 1
        return granted
    }
}

@MainActor
private final class QRControlledAuthorization: CameraAuthorizationProviding {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var requestCount = 0

    func authorizationStatus() -> AVAuthorizationStatus { .notDetermined }

    func requestAccess() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor
private final class QRRecordingCapture: QRCodeCaptureSessionProviding {
    let previewLayer: AVCaptureVideoPreviewLayer? = nil
    private(set) var configureCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate) -> Bool {
        configureCount += 1
        return true
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}
