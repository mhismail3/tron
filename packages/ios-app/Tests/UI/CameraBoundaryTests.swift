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

    @Test("permission cancellation does not publish denial or begin setup")
    func canceledPermissionRequest() async {
        let authorization = RecordingCameraAuthorization(status: .notDetermined, deferRequest: true)
        let sessions = RecordingCameraSessions(configuration: .fixture())
        let model = CameraModel(authorization: authorization, sessions: sessions)
        let request = Task { await model.requestPermissionAndSetup() }
        await Task.yield()
        request.cancel()
        authorization.completeRequest(false)
        await request.value

        #expect(model.isAuthorized == false)
        #expect(model.permissionDenied == false)
        #expect(sessions.configuredPositions.isEmpty)
    }

    @Test("authorized retry clears a prior denied state")
    func authorizedRetryClearsDenial() async {
        let authorization = RecordingCameraAuthorization(status: .denied)
        let sessions = RecordingCameraSessions(configuration: .fixture())
        let model = CameraModel(authorization: authorization, sessions: sessions)
        await model.requestPermissionAndSetup()
        #expect(model.permissionDenied)

        authorization.status = .authorized
        await model.requestPermissionAndSetup()
        #expect(model.isAuthorized)
        #expect(!model.permissionDenied)
        #expect(model.isReady)
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
        model.flipCamera() // Capturing owns the camera generation.
        model.cancelCapture()
        model.flipCamera()

        #expect(sessions.stopCount == 2)
        #expect(sessions.startCount == 3)
        #expect(sessions.torchRequests == [true, false])
        #expect(sessions.captureCount == 1)
        #expect(sessions.configuredPositions == [.back, .front])
        #expect(!model.isTorchOn)
        #expect(model.isReady)
    }

    @Test("late torch completion after dismissal cannot publish state")
    func dismissedTorchCompletion() async {
        let sessions = RecordingCameraSessions(configuration: .fixture(), deferTorch: true)
        let model = CameraModel(
            authorization: RecordingCameraAuthorization(status: .authorized),
            sessions: sessions
        )
        await model.requestPermissionAndSetup()
        model.toggleTorch()
        model.stopSession()
        sessions.completeTorch(true)
        #expect(!model.isTorchOn)
    }

    @Test("capture is single-flight and can be reused after an immediate failure")
    func captureSingleFlightAndReuse() {
        let sessions = RecordingCameraSessions(configuration: nil)
        let model = CameraModel(
            authorization: RecordingCameraAuthorization(status: .denied),
            sessions: sessions
        )
        var completions = 0
        model.capturePhoto { image in
            #expect(image == nil)
            completions += 1
        }
        model.capturePhoto { _ in completions += 100 }
        model.capturePhoto { image in
            #expect(image == nil)
            completions += 1
        }
        #expect(completions == 102)
        #expect(!model.isCapturing)
        #expect(sessions.captureCount == 0)
    }

    @Test("dismissal cancellation settles once and revokes deferred configuration")
    func dismissalCancellationAndDeferredConfiguration() async {
        let sessions = RecordingCameraSessions(configuration: .fixture(), deferConfiguration: true)
        let model = CameraModel(
            authorization: RecordingCameraAuthorization(status: .authorized),
            sessions: sessions
        )
        let setup = Task { await model.requestPermissionAndSetup() }
        await Task.yield()
        model.stopSession()
        sessions.completeConfiguration()
        await setup.value
        #expect(!model.isReady)
        #expect(sessions.configuredPositions == [.back])
        #expect(sessions.startCount == 0)

        let immediate = RecordingCameraSessions(configuration: .fixture())
        let reused = CameraModel(
            authorization: RecordingCameraAuthorization(status: .authorized),
            sessions: immediate
        )
        await reused.requestPermissionAndSetup()
        var callbacks = 0
        reused.capturePhoto { _ in callbacks += 1 }
        reused.cancelCapture()
        reused.cancelCapture()
        #expect(callbacks == 1)
        #expect(!reused.isCapturing)
    }

    @Test("second capture cannot replace an in-flight callback")
    func captureInFlight() async {
        let sessions = RecordingCameraSessions(configuration: .fixture())
        let model = CameraModel(
            authorization: RecordingCameraAuthorization(status: .authorized),
            sessions: sessions
        )
        await model.requestPermissionAndSetup()
        model.capturePhoto { _ in }
        model.capturePhoto { _ in }
        #expect(model.isCapturing)
        #expect(sessions.captureCount == 1)
    }
}

@MainActor
private final class RecordingCameraAuthorization: CameraAuthorizationProviding {
    var status: AVAuthorizationStatus
    let granted: Bool
    let deferRequest: Bool
    private var requestContinuation: CheckedContinuation<Bool, Never>?
    private(set) var requestCount = 0

    init(status: AVAuthorizationStatus, granted: Bool = false, deferRequest: Bool = false) {
        self.status = status
        self.granted = granted
        self.deferRequest = deferRequest
    }

    func authorizationStatus() -> AVAuthorizationStatus { status }

    func requestAccess() async -> Bool {
        requestCount += 1
        guard deferRequest else { return granted }
        return await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func completeRequest(_ granted: Bool) {
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(returning: granted)
    }
}

@MainActor
private final class RecordingCameraSessions: CameraSessionProviding {
    let configuration: CameraSessionConfiguration?
    let deferConfiguration: Bool
    let deferTorch: Bool
    private var configurationCompletion: (@MainActor @Sendable (CameraSessionConfiguration?) -> Void)?
    private var torchCompletion: (@MainActor @Sendable (Bool) -> Void)?
    private(set) var configuredPositions: [AVCaptureDevice.Position] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var torchRequests: [Bool] = []
    private(set) var captureCount = 0

    init(configuration: CameraSessionConfiguration?, deferConfiguration: Bool = false, deferTorch: Bool = false) {
        self.configuration = configuration
        self.deferConfiguration = deferConfiguration
        self.deferTorch = deferTorch
    }

    func configure(
        position: AVCaptureDevice.Position,
        completion: @escaping @MainActor @Sendable (CameraSessionConfiguration?) -> Void
    ) {
        configuredPositions.append(position)
        if deferConfiguration { configurationCompletion = completion } else { completion(configuration) }
    }

    func completeConfiguration() {
        let callback = configurationCompletion
        configurationCompletion = nil
        callback?(configuration)
    }

    func start(_ session: AVCaptureSession) { startCount += 1 }
    func stop(_ session: AVCaptureSession) { stopCount += 1 }

    func setTorch(
        on: Bool,
        session: AVCaptureSession,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        torchRequests.append(on)
        if deferTorch {
            torchCompletion = completion
        } else {
            completion(on)
        }
    }

    func completeTorch(_ enabled: Bool) {
        let completion = torchCompletion
        torchCompletion = nil
        completion?(enabled)
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
