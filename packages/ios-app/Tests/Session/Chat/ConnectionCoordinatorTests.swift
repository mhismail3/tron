import XCTest
@testable import TronMobile

/// Tests for ConnectionCoordinator - handles session connection, reconnection, and reconstruction.
@MainActor
final class ConnectionCoordinatorTests: XCTestCase {

    var coordinator: ConnectionCoordinator!
    var mockContext: MockConnectionContext!

    override func setUp() async throws {
        mockContext = MockConnectionContext()
        coordinator = ConnectionCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Connect and Reconstruct Tests

    func testReadOnlyReconstructionNeverResumesInteractiveSession() async {
        mockContext.isConnected = true

        let outcome = await coordinator.reconstructReadOnly(context: mockContext)

        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(mockContext.connectCalled)
        XCTAssertFalse(mockContext.resumeSessionCalled)
        XCTAssertTrue(mockContext.reconstructSessionCalled)
        XCTAssertTrue(mockContext.processReconstructionResultCalled)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testReadOnlyReconstructionUsesBoundedAuditOverride() async {
        mockContext.isConnected = true
        mockContext.reconstructionEventLimit = 300

        let outcome = await coordinator.reconstructReadOnly(
            context: mockContext,
            eventLimit: 120
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(mockContext.lastReconstructLimit, 120)
    }

    func testReadOnlyReconstructionFailureReleasesGateAndUsesWorkerError() async {
        mockContext.isConnected = true
        mockContext.reconstructShouldFail = true

        let outcome = await coordinator.reconstructReadOnly(context: mockContext)

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertFalse(mockContext.resumeSessionCalled)
        XCTAssertFalse(mockContext.isReconstructing)
        XCTAssertEqual(mockContext.lastLocalErrorDedupKey, "worker.session.reconstruct.failed")
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not load worker session")
    }

    func testConnectAndReconstructCallsConnect() async {
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.connectCalled)
    }

    func testConnectAndReconstructCallsResumeSession() async {
        mockContext.isConnected = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.resumeSessionCalled)
        XCTAssertEqual(mockContext.lastResumeSessionId, "test-session")
    }

    func testConnectAndReconstructDoesNotResumeIfNotConnected() async {
        mockContext.connectWillSucceed = false
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.resumeSessionCalled)
    }

    func testConnectAndReconstructCallsReconstruct() async {
        mockContext.isConnected = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.reconstructSessionCalled)
    }

    func testConnectAndReconstructEstablishesLiveLaneBeforeSnapshot() async {
        mockContext.isConnected = true

        let outcome = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertEqual(
            mockContext.connectionCallOrder,
            ["connect", "resume", "subscribe", "reconstruct"]
        )
    }

    func testLiveLaneFailureDoesNotFetchSnapshotAcrossAGap() async {
        mockContext.isConnected = true
        mockContext.liveEventSubscriptionError = EngineConnectionError.notConnected

        let outcome = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertFalse(mockContext.reconstructSessionCalled)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.appendLocalErrorCalled)
    }

    func testConnectAndReconstructUsesContextReconstructionLimit() async {
        mockContext.isConnected = true
        mockContext.reconstructionEventLimit = 250

        _ = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(mockContext.lastReconstructLimit, 250)
    }

    func testConnectAndReconstructSetsShouldDismissOnSessionNotFound() async {
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.sessionNotFound
        let outcome = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.shouldDismiss)
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertEqual(outcome, .terminalFailure)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.drainEventBufferCalled)
    }

    func testConnectAndReconstructDoesNotDismissOnOtherErrors() async {
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.generic
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.shouldDismiss)
    }

    func testConnectAndReconstructSetsProcessingWhenRunning() async {
        mockContext.isConnected = true
        mockContext.reconstructResultIsRunning = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.isProcessing)
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
    }

    func testConnectAndReconstructDoesNotSetProcessingWhenIdle() async {
        mockContext.isConnected = true
        mockContext.agentPhase = .processing
        mockContext.reconstructResultIsRunning = false
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertEqual(mockContext.agentPhase, .idle)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, false)
    }

    func testConnectAndReconstructPreservesStoppingWhileServerRunIsActive() async {
        mockContext.isConnected = true
        mockContext.agentPhase = .stopping
        mockContext.reconstructResultIsRunning = true

        _ = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(mockContext.agentPhase, .stopping)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, true)
    }

    func testConnectAndReconstructSetsHighWaterMark() async {
        mockContext.isConnected = true
        mockContext.reconstructResultLastSequence = 42
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertEqual(mockContext.sequenceHighWaterMark, 42)
        XCTAssertEqual(mockContext.sequenceHighWaterMarkDuringProcessing, 42)
    }

    func testConnectAndReconstructCallsCleanUpStreamingState() async {
        mockContext.isConnected = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.cleanUpStreamingStateCalled)
    }

    func testConnectAndReconstructProcessesResult() async {
        mockContext.isConnected = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.processReconstructionResultCalled)
    }

    // MARK: - Reconstruction Flag Tests

    func testIsReconstructingSetBeforeConnect() async {
        mockContext.captureReconstructingDuringConnect = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.wasReconstructingDuringConnect)
    }

    func testIsReconstructingClearedAfterReconstruction() async {
        mockContext.isConnected = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testConnectionFailureRetainsReconstructionGateAndBufferForRetry() async {
        mockContext.connectWillSucceed = false
        let outcome = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.drainEventBufferCalled)
    }

    func testResumeFailureRetainsReconstructionGateAndBufferForRetry() async {
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.generic
        let outcome = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.drainEventBufferCalled)
    }

    func testDrainEventBufferCalledAfterReconstruction() async {
        mockContext.isConnected = true
        _ = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.drainEventBufferCalled)
    }

    func testReconstructionErrorRetainsGateAndBufferForRetry() async {
        mockContext.isConnected = true
        mockContext.reconstructShouldFail = true
        let outcome = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertFalse(mockContext.drainEventBufferCalled)
        XCTAssertTrue(mockContext.isReconstructing)
    }

    func testSuccessfulRetryCommitsAndReleasesPreviouslyRetainedBuffer() async {
        mockContext.isConnected = true
        mockContext.reconstructShouldFail = true

        let failedOutcome = await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertEqual(failedOutcome, .retryableFailure)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.drainEventBufferCalled)

        mockContext.reconstructShouldFail = false
        mockContext.reconstructResultLastSequence = 42
        let retryOutcome = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(retryOutcome, .completed)
        XCTAssertEqual(mockContext.sequenceHighWaterMark, 42)
        XCTAssertFalse(mockContext.isReconstructing)
        XCTAssertTrue(mockContext.drainEventBufferCalled)
    }

    func testReconstructionFailureSurfacesLocalLoadError() async {
        mockContext.isConnected = true
        mockContext.reconstructShouldFail = true

        _ = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertEqual(mockContext.lastLocalErrorDedupKey, "session.reconstruct.failed")
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not load chat")
        XCTAssertEqual(
            mockContext.lastLocalErrorSuggestion,
            "Check the connection. Tron will retry while the server remains reachable."
        )
    }

    func testTransientReconstructionFailureStaysOutOfTimeline() async {
        mockContext.isConnected = true
        mockContext.reconstructError = URLError(.networkConnectionLost)

        let outcome = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.appendLocalErrorCalled)
        XCTAssertFalse(mockContext.drainEventBufferCalled)
    }

    func testSuccessfulRetryRemovesOnlyReconstructionError() async {
        mockContext.isConnected = true

        let outcome = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(
            mockContext.removedLocalNotificationDedupKeys,
            ["session.reconstruct.failed"]
        )
    }

    func testReadOnlyTransientFailureStaysOutOfTimeline() async {
        mockContext.isConnected = true
        mockContext.reconstructError = EngineConnectionError.timeout

        let outcome = await coordinator.reconstructReadOnly(context: mockContext)

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertFalse(mockContext.appendLocalErrorCalled)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testCancellationDuringProjectionRetainsCommittedCutAndBufferedSuffix() async {
        mockContext.isConnected = true
        mockContext.reconstructResultLastSequence = 42
        var releaseProjection: CheckedContinuation<Void, Never>?
        mockContext.processReconstructionResultHandler = {
            await withCheckedContinuation { continuation in
                releaseProjection = continuation
            }
        }

        let attempt = Task { @MainActor in
            await coordinator.connectAndReconstruct(context: mockContext)
        }
        while releaseProjection == nil { await Task.yield() }

        XCTAssertEqual(mockContext.sequenceHighWaterMark, 42)
        XCTAssertEqual(mockContext.sequenceHighWaterMarkDuringProcessing, 42)
        XCTAssertTrue(mockContext.isReconstructing)

        attempt.cancel()
        releaseProjection?.resume()
        let outcome = await attempt.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(mockContext.isReconstructing)
        XCTAssertFalse(mockContext.drainEventBufferCalled)
    }

    func testSuccessfulEmptyReconstructionStaysQuiet() async {
        mockContext.isConnected = true

        _ = await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertFalse(mockContext.appendLocalErrorCalled)
        XCTAssertFalse(mockContext.showErrorCalled)
        XCTAssertTrue(mockContext.processReconstructionResultCalled)
    }

}

// MARK: - Test Error

enum ConnectionTestError: Error, LocalizedError {
    case sessionNotFound
    case generic

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: return "Session not found on server"
        case .generic: return "Connection error"
        }
    }
}

// MARK: - Mock Context

@MainActor
final class MockConnectionContext: ConnectionContext {
    // MARK: - State
    var sessionId: String = "test-session"
    var agentPhase: AgentPhase = .idle
    var isProcessing: Bool { agentPhase.isProcessing }
    var shouldDismiss: Bool = false
    var isConnected: Bool = false
    var isReconstructing: Bool = false
    var sequenceHighWaterMark: Int64 = -1
    var reconstructionEventLimit: Int = 100

    // MARK: - Tracking
    var connectCalled = false
    var resumeSessionCalled = false
    var lastResumeSessionId: String?
    var reconstructSessionCalled = false
    var lastReconstructLimit: Int?
    var processReconstructionResultCalled = false
    var sequenceHighWaterMarkDuringProcessing: Int64?
    var processReconstructionResultHandler: (() async -> Void)?
    var setSessionProcessingCalled = false
    var lastSessionProcessingValue: Bool?
    var showErrorCalled = false
    var appendLocalErrorCalled = false
    var lastLocalErrorDedupKey: String?
    var lastLocalErrorTitle: String?
    var lastLocalErrorMessage: String?
    var lastLocalErrorSuggestion: String?
    var cleanUpStreamingStateCalled = false
    var drainEventBufferCalled = false
    var ensureLiveEventSubscriptionCalled = false
    var removedLocalNotificationDedupKeys: [String] = []
    var connectionCallOrder: [String] = []
    var captureReconstructingDuringConnect = false
    var wasReconstructingDuringConnect = false

    // MARK: - Configuration
    var connectWillSucceed = true
    var resumeSessionError: Error?
    var reconstructShouldFail = false
    var reconstructError: Error?
    var liveEventSubscriptionError: Error?
    var reconstructResultIsRunning = false
    var reconstructResultLastSequence: Int64 = 0

    // MARK: - Protocol Methods

    func connect() async {
        connectionCallOrder.append("connect")
        connectCalled = true
        if captureReconstructingDuringConnect {
            wasReconstructingDuringConnect = isReconstructing
        }
        if connectWillSucceed {
            isConnected = true
        }
    }

    func resumeSession(sessionId: String) async throws {
        connectionCallOrder.append("resume")
        resumeSessionCalled = true
        lastResumeSessionId = sessionId
        if let error = resumeSessionError { throw error }
    }

    func reconstructSession(sessionId: String, limit: Int?, beforeEventId: String?) async throws -> SessionReconstructResult {
        connectionCallOrder.append("reconstruct")
        reconstructSessionCalled = true
        lastReconstructLimit = limit
        if let reconstructError { throw reconstructError }
        if reconstructShouldFail { throw ConnectionTestError.generic }

        let json = """
        {
            "events": [],
            "hasMoreEvents": false,
            "oldestEventId": null,
            "inFlight": null,
            "lastSequence": \(reconstructResultLastSequence),
            "isRunning": \(reconstructResultIsRunning),
            "agentPhase": "\(reconstructResultIsRunning ? "processing" : "idle")",
            "metadata": {
                "model": "test-model",
                "turnCount": 0,
                "workingDirectory": "/tmp",
                "tokenUsage": {
                    "input": 5000,
                    "output": 1200,
                    "cacheRead": 3800,
                    "cacheCreation": 200
                },
                "totalCost": 0.042
            }
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(SessionReconstructResult.self, from: json)
    }

    func processReconstructionResult(_ result: SessionReconstructResult) async {
        processReconstructionResultCalled = true
        sequenceHighWaterMarkDuringProcessing = sequenceHighWaterMark
        switch result.agentPhase {
        case "processing" where agentPhase == .stopping: break
        case "processing": agentPhase = .processing
        default: agentPhase = .idle
        }
        await processReconstructionResultHandler?()
    }

    func cleanUpStreamingState() {
        cleanUpStreamingStateCalled = true
    }

    func drainEventBuffer() {
        drainEventBufferCalled = true
    }

    func ensureLiveEventSubscription() async throws {
        connectionCallOrder.append("subscribe")
        ensureLiveEventSubscriptionCalled = true
        if let liveEventSubscriptionError { throw liveEventSubscriptionError }
    }

    func setSessionProcessing(_ isProcessing: Bool) {
        setSessionProcessingCalled = true
        lastSessionProcessingValue = isProcessing
    }

    func showError(_ message: String) {
        showErrorCalled = true
    }

    func appendLocalError(dedupKey: String, title: String, message: String, suggestion: String?) {
        appendLocalErrorCalled = true
        lastLocalErrorDedupKey = dedupKey
        lastLocalErrorTitle = title
        lastLocalErrorMessage = message
        lastLocalErrorSuggestion = suggestion
    }

    func removeLocalNotification(dedupKey: String) {
        removedLocalNotificationDedupKeys.append(dedupKey)
    }

    // MARK: - Logging (no-op)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
