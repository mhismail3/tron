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

    func testConnectAndReconstructCallsConnect() async {
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.connectCalled)
    }

    func testConnectAndReconstructCallsResumeSession() async {
        mockContext.isConnected = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.resumeSessionCalled)
        XCTAssertEqual(mockContext.lastResumeSessionId, "test-session")
    }

    func testConnectAndReconstructDoesNotResumeIfNotConnected() async {
        mockContext.connectWillSucceed = false
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.resumeSessionCalled)
    }

    func testConnectAndReconstructCallsReconstruct() async {
        mockContext.isConnected = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.reconstructSessionCalled)
    }

    func testConnectAndReconstructSetsShouldDismissOnSessionNotFound() async {
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.sessionNotFound
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.shouldDismiss)
        XCTAssertTrue(mockContext.showErrorCalled)
    }

    func testConnectAndReconstructDoesNotDismissOnOtherErrors() async {
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.generic
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.shouldDismiss)
    }

    func testConnectAndReconstructSetsProcessingWhenRunning() async {
        mockContext.isConnected = true
        mockContext.reconstructResultIsRunning = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.isProcessing)
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
    }

    func testConnectAndReconstructDoesNotSetProcessingWhenIdle() async {
        mockContext.isConnected = true
        mockContext.agentPhase = .processing
        mockContext.reconstructResultIsRunning = false
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertEqual(mockContext.agentPhase, .idle)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, false)
    }

    func testConnectAndReconstructSetsHighWaterMark() async {
        mockContext.isConnected = true
        mockContext.reconstructResultLastSequence = 42
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertEqual(mockContext.sequenceHighWaterMark, 42)
    }

    func testConnectAndReconstructCallsCleanUpStreamingState() async {
        mockContext.isConnected = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.cleanUpStreamingStateCalled)
    }

    func testConnectAndReconstructProcessesResult() async {
        mockContext.isConnected = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.processReconstructionResultCalled)
    }

    // MARK: - Reconstruction Flag Tests

    func testIsReconstructingSetBeforeConnect() async {
        mockContext.captureReconstructingDuringConnect = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.wasReconstructingDuringConnect)
    }

    func testIsReconstructingClearedAfterReconstruction() async {
        mockContext.isConnected = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testIsReconstructingClearedOnConnectionFailure() async {
        mockContext.connectWillSucceed = false
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testIsReconstructingClearedOnResumeFailure() async {
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.generic
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testDrainEventBufferCalledAfterReconstruction() async {
        mockContext.isConnected = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.drainEventBufferCalled)
    }

    func testDrainEventBufferCalledOnReconstructionError() async {
        mockContext.isConnected = true
        mockContext.reconstructShouldFail = true
        await coordinator.connectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.drainEventBufferCalled)
        XCTAssertFalse(mockContext.isReconstructing)
    }

    func testReconstructionFailureSurfacesLocalLoadError() async {
        mockContext.isConnected = true
        mockContext.reconstructShouldFail = true

        await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertEqual(mockContext.lastLocalErrorDedupKey, "session.reconstruct.failed")
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not load chat")
        XCTAssertEqual(
            mockContext.lastLocalErrorSuggestion,
            "Check the connection, then reopen this chat to retry loading history."
        )
    }

    func testSuccessfulEmptyReconstructionStaysQuiet() async {
        mockContext.isConnected = true

        await coordinator.connectAndReconstruct(context: mockContext)

        XCTAssertFalse(mockContext.appendLocalErrorCalled)
        XCTAssertFalse(mockContext.showErrorCalled)
        XCTAssertTrue(mockContext.processReconstructionResultCalled)
    }

    // MARK: - Reconnect Tests

    func testReconnectAndReconstructCallsReconstruct() async {
        mockContext.isConnected = true
        await coordinator.reconnectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.reconstructSessionCalled)
    }

    func testReconnectAndReconstructConnectsIfNeeded() async {
        mockContext.isConnected = false
        mockContext.connectWillSucceed = true
        await coordinator.reconnectAndReconstruct(context: mockContext)
        XCTAssertTrue(mockContext.connectCalled)
    }

    // MARK: - Disconnect Tests

    func testDisconnectCallsRpcDisconnect() async {
        await coordinator.disconnect(context: mockContext)
        XCTAssertTrue(mockContext.disconnectCalled)
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
    var shouldDismiss: Bool = false
    var isConnected: Bool = false
    var isReconstructing: Bool = false
    var sequenceHighWaterMark: Int64 = -1

    // MARK: - Tracking
    var connectCalled = false
    var disconnectCalled = false
    var resumeSessionCalled = false
    var lastResumeSessionId: String?
    var reconstructSessionCalled = false
    var processReconstructionResultCalled = false
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
    var captureReconstructingDuringConnect = false
    var wasReconstructingDuringConnect = false

    // MARK: - Configuration
    var connectWillSucceed = true
    var resumeSessionError: Error?
    var reconstructShouldFail = false
    var reconstructResultIsRunning = false
    var reconstructResultLastSequence: Int64 = 0

    // MARK: - Protocol Methods

    func connect() async {
        connectCalled = true
        if captureReconstructingDuringConnect {
            wasReconstructingDuringConnect = isReconstructing
        }
        if connectWillSucceed {
            isConnected = true
        }
    }

    func disconnect() async {
        disconnectCalled = true
        isConnected = false
    }

    func resumeSession(sessionId: String) async throws {
        resumeSessionCalled = true
        lastResumeSessionId = sessionId
        if let error = resumeSessionError { throw error }
    }

    func reconstructSession(sessionId: String, limit: Int?, beforeEventId: String?) async throws -> SessionReconstructResult {
        reconstructSessionCalled = true
        if reconstructShouldFail { throw ConnectionTestError.generic }

        let json = """
        {
            "events": [],
            "hasMoreEvents": false,
            "oldestEventId": null,
            "inFlight": null,
            "lastSequence": \(reconstructResultLastSequence),
            "isRunning": \(reconstructResultIsRunning),
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
    }

    func cleanUpStreamingState() {
        cleanUpStreamingStateCalled = true
    }

    func drainEventBuffer() {
        drainEventBufferCalled = true
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

    // MARK: - Logging (no-op)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
