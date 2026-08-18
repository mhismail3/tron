@preconcurrency import AVFoundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Camera system-service boundaries")
struct CameraBoundaryTests {
    @Test("authorized camera configures once and becomes ready")
    func authorizedSetup() async {
        let authorization = RecordingCameraAuthorization(status: .authorized)
        let sessions = RecordingCameraSessions(configuration: .fixture(hasTorch: true))
        let model = CameraModel(authorization: authorization, sessions: sessions)

        await model.requestPermissionAndSetup()

        #expect(authorization.requestCount == 0)
        #expect(sessions.configuredPositions == [.back])
        #expect(model.isAuthorized)
        #expect(model.isReady)
        #expect(model.hasTorch)
        #expect(!model.permissionDenied)
        #expect(!model.cameraUnavailable)
    }

    @Test("undetermined permission requests once and admits only a grant", arguments: [true, false])
    func permissionRequest(granted: Bool) async {
        let authorization = RecordingCameraAuthorization(status: .notDetermined, granted: granted)
        let sessions = RecordingCameraSessions(configuration: .fixture())
        let model = CameraModel(authorization: authorization, sessions: sessions)

        await model.requestPermissionAndSetup()

        #expect(authorization.requestCount == 1)
        #expect(model.isAuthorized == granted)
        #expect(model.permissionDenied == !granted)
        #expect(sessions.configuredPositions == (granted ? [.back] : []))
    }

    @Test("denied permission and failed setup never become ready")
    func unavailableStates() async {
        let deniedSessions = RecordingCameraSessions(configuration: .fixture())
        let denied = CameraModel(
            authorization: RecordingCameraAuthorization(status: .denied),
            sessions: deniedSessions
        )
        await denied.requestPermissionAndSetup()

        let failedSessions = RecordingCameraSessions(configuration: nil)
        let failed = CameraModel(
            authorization: RecordingCameraAuthorization(status: .authorized),
            sessions: failedSessions
        )
        await failed.requestPermissionAndSetup()

        #expect(denied.permissionDenied)
        #expect(deniedSessions.configuredPositions.isEmpty)
        #expect(!denied.isReady)
        #expect(failed.cameraUnavailable)
        #expect(!failed.isReady)
    }

    @Test("session commands and camera flip remain owned by the injected adapter")
    func sessionCommands() async {
        let sessions = RecordingCameraSessions(configuration: .fixture(hasTorch: true))
        let model = CameraModel(
            authorization: RecordingCameraAuthorization(status: .authorized),
            sessions: sessions
        )
        await model.requestPermissionAndSetup()

        model.stopSession()
        model.startSession()
        model.toggleTorch()
        model.toggleTorch()
        model.capturePhoto { _ in }
        model.flipCamera()

        #expect(sessions.stopCount == 2)
        #expect(sessions.startCount == 1)
        #expect(sessions.torchRequests == [true, false])
        #expect(sessions.captureCount == 1)
        #expect(sessions.configuredPositions == [.back, .front])
        #expect(!model.isTorchOn)
        #expect(model.isReady)
    }

    @Test("capture without configured output completes once with no image")
    func captureWithoutOutput() {
        let model = CameraModel(
            authorization: RecordingCameraAuthorization(status: .denied),
            sessions: RecordingCameraSessions(configuration: nil)
        )
        var completions = 0
        model.capturePhoto { image in
            #expect(image == nil)
            completions += 1
        }
        #expect(completions == 1)
    }
}

@MainActor
private final class RecordingCameraAuthorization: CameraAuthorizationProviding {
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
private final class RecordingCameraSessions: CameraSessionProviding {
    let configuration: CameraSessionConfiguration?
    private(set) var configuredPositions: [AVCaptureDevice.Position] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var torchRequests: [Bool] = []
    private(set) var captureCount = 0

    init(configuration: CameraSessionConfiguration?) {
        self.configuration = configuration
    }

    func configure(
        position: AVCaptureDevice.Position,
        completion: @escaping @MainActor @Sendable (CameraSessionConfiguration?) -> Void
    ) {
        configuredPositions.append(position)
        completion(configuration)
    }

    func start(_ session: AVCaptureSession) { startCount += 1 }
    func stop(_ session: AVCaptureSession) { stopCount += 1 }

    func setTorch(
        on: Bool,
        session: AVCaptureSession,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        torchRequests.append(on)
        completion(on)
    }

    func capturePhoto(_ request: CameraPhotoCaptureRequest) {
        captureCount += 1
    }
}

private extension CameraSessionConfiguration {
    static func fixture(hasTorch: Bool = false) -> CameraSessionConfiguration {
        CameraSessionConfiguration(
            session: AVCaptureSession(),
            photoOutput: AVCapturePhotoOutput(),
            hasTorch: hasTorch
        )
    }
}
