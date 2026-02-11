import XCTest
@testable import TronMobile

/// Tests for ConnectionCoordinator - handles session connection, reconnection, and catch-up
/// Uses TDD: Tests written first, then implementation follows
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

    // MARK: - Connect and Resume Tests

    func testConnectAndResumeCallsConnect() async {
        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should call connect
        XCTAssertTrue(mockContext.connectCalled)
    }

    func testConnectAndResumeCallsResumeSession() async {
        // Given: Connection will succeed
        mockContext.isConnected = true

        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should call resume session
        XCTAssertTrue(mockContext.resumeSessionCalled)
        XCTAssertEqual(mockContext.lastResumeSessionId, "test-session")
    }

    func testConnectAndResumeDoesNotResumeIfNotConnected() async {
        // Given: Connection will fail
        mockContext.connectWillSucceed = false

        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should NOT call resume session
        XCTAssertFalse(mockContext.resumeSessionCalled)
    }

    func testConnectAndResumeChecksAgentStateAfterResume() async {
        // Given: Connection succeeds
        mockContext.isConnected = true

        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should check agent state
        XCTAssertTrue(mockContext.getAgentStateCalled)
    }

    func testConnectAndResumeFetchesTasksAfterResume() async {
        // Given: Connection succeeds
        mockContext.isConnected = true

        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should fetch tasks
        XCTAssertTrue(mockContext.listTasksCalled)
    }

    func testConnectAndResumeSetsShouldDismissOnSessionNotFound() async {
        // Given: Session not found error
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.sessionNotFound

        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should set shouldDismiss and show error
        XCTAssertTrue(mockContext.shouldDismiss)
        XCTAssertTrue(mockContext.showErrorAlertCalled)
    }

    func testConnectAndResumeDoesNotDismissOnOtherErrors() async {
        // Given: Generic error
        mockContext.isConnected = true
        mockContext.resumeSessionError = ConnectionTestError.generic

        // When: Connect and resume
        await coordinator.connectAndResume(context: mockContext)

        // Then: Should NOT set shouldDismiss
        XCTAssertFalse(mockContext.shouldDismiss)
        XCTAssertFalse(mockContext.showErrorAlertCalled)
    }

    // MARK: - Reconnect and Resume Tests

    func testReconnectAndResumeSkipsConnectIfAlreadyConnected() async {
        // Given: Already connected
        mockContext.isConnected = true

        // When: Reconnect and resume
        await coordinator.reconnectAndResume(context: mockContext)

        // Then: Should NOT call connect (already connected)
        XCTAssertFalse(mockContext.connectCalled)
        // But should check agent state
        XCTAssertTrue(mockContext.getAgentStateCalled)
    }

    func testReconnectAndResumeConnectsIfNotConnected() async {
        // Given: Not connected, but connect will succeed
        mockContext.isConnected = false
        mockContext.connectWillSucceed = true

        // When: Reconnect and resume
        await coordinator.reconnectAndResume(context: mockContext)

        // Then: Should call connect
        XCTAssertTrue(mockContext.connectCalled)
    }

    func testReconnectAndResumeResumesSessionAfterReconnect() async {
        // Given: Not connected, connect will succeed
        mockContext.isConnected = false
        mockContext.connectWillSucceed = true

        // When: Reconnect and resume
        await coordinator.reconnectAndResume(context: mockContext)

        // Then: Should resume session
        XCTAssertTrue(mockContext.resumeSessionCalled)
    }

    func testReconnectAndResumeStopsIfReconnectFails() async {
        // Given: Not connected, connect will fail
        mockContext.isConnected = false
        mockContext.connectWillSucceed = false

        // When: Reconnect and resume
        await coordinator.reconnectAndResume(context: mockContext)

        // Then: Should NOT check agent state
        XCTAssertFalse(mockContext.getAgentStateCalled)
    }

    func testReconnectAndResumeFetchesTasks() async {
        // Given: Already connected
        mockContext.isConnected = true

        // When: Reconnect and resume
        await coordinator.reconnectAndResume(context: mockContext)

        // Then: Should fetch tasks
        XCTAssertTrue(mockContext.listTasksCalled)
    }

    // MARK: - Check and Resume Agent State Tests

    func testCheckAgentStateSetsProcessingWhenAgentRunning() async {
        // Given: Agent is running
        mockContext.agentStateIsRunning = true

        // When: Check agent state
        await coordinator.checkAndResumeAgentState(context: mockContext)

        // Then: isProcessing should be true
        XCTAssertTrue(mockContext.isProcessing)
    }

    func testCheckAgentStateAppendsCatchingUpMessageWhenRunning() async {
        // Given: Agent is running
        mockContext.agentStateIsRunning = true

        // When: Check agent state
        await coordinator.checkAndResumeAgentState(context: mockContext)

        // Then: Should append catching up message
        XCTAssertTrue(mockContext.appendCatchingUpMessageCalled)
    }

    func testCheckAgentStateUpdatesSessionProcessingWhenRunning() async {
        // Given: Agent is running
        mockContext.agentStateIsRunning = true

        // When: Check agent state
        await coordinator.checkAndResumeAgentState(context: mockContext)

        // Then: Should set session processing
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
        XCTAssertTrue(mockContext.lastSessionProcessingValue ?? false)
    }

    func testCheckAgentStateDoesNotSetProcessingWhenNotRunning() async {
        // Given: Agent is not running
        mockContext.agentStateIsRunning = false

        // When: Check agent state
        await coordinator.checkAndResumeAgentState(context: mockContext)

        // Then: isProcessing should remain false
        XCTAssertFalse(mockContext.isProcessing)
    }

    func testCheckAgentStateProcessesCatchUpContent() async {
        // Given: Agent is running with accumulated content
        mockContext.agentStateIsRunning = true
        mockContext.agentStateCurrentTurnText = "Hello world"
        mockContext.agentStateToolCalls = [
            TestToolCall(
                toolCallId: "tool-1",
                toolName: "Read",
                status: "completed",
                result: "file contents",
                isError: false,
                startedAt: "2024-01-01T00:00:00Z",
                completedAt: "2024-01-01T00:00:01Z"
            )
        ]

        // When: Check agent state
        await coordinator.checkAndResumeAgentState(context: mockContext)

        // Then: Should process catch-up content
        XCTAssertTrue(mockContext.processCatchUpContentCalled)
        XCTAssertEqual(mockContext.lastCatchUpText, "Hello world")
        XCTAssertEqual(mockContext.lastCatchUpToolCalls?.count, 1)
    }

    func testCheckAgentStateHandlesError() async {
        // Given: Get state will fail
        mockContext.getAgentStateShouldFail = true

        // When: Check agent state
        await coordinator.checkAndResumeAgentState(context: mockContext)

        // Then: Should not crash, isProcessing stays false
        XCTAssertFalse(mockContext.isProcessing)
    }

    // MARK: - Fetch Tasks Tests

    func testFetchTasksUpdatesTaskState() async {
        // Given: Tasks available
        mockContext.tasksResult = createMockTaskListResult(count: 1)

        // When: Fetch tasks
        await coordinator.fetchTasksOnResume(context: mockContext)

        // Then: Should update task state
        XCTAssertTrue(mockContext.updateTasksCalled)
        XCTAssertEqual(mockContext.lastTasksCount, 1)
    }

    func testFetchTasksHandlesError() async {
        // Given: Fetch will fail
        mockContext.listTasksShouldFail = true

        // When: Fetch tasks
        await coordinator.fetchTasksOnResume(context: mockContext)

        // Then: Should not crash, just log warning
        XCTAssertFalse(mockContext.updateTasksCalled)
    }

    // MARK: - Disconnect Tests

    func testDisconnectCallsRpcDisconnect() async {
        // When: Disconnect
        await coordinator.disconnect(context: mockContext)

        // Then: Should call disconnect
        XCTAssertTrue(mockContext.disconnectCalled)
    }

    // MARK: - History to Message Tests

    func testHistoryToMessageConvertsUserRole() {
        // Given: User history message
        let history = createMockHistoryMessage(role: "user", content: "Hello")

        // When: Convert to message
        let message = coordinator.historyToMessage(history)

        // Then: Should have user role
        XCTAssertEqual(message.role, .user)
        if case .text(let text) = message.content {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testHistoryToMessageConvertsAssistantRole() {
        // Given: Assistant history message
        let history = createMockHistoryMessage(role: "assistant", content: "Hi there")

        // When: Convert to message
        let message = coordinator.historyToMessage(history)

        // Then: Should have assistant role
        XCTAssertEqual(message.role, .assistant)
    }

    func testHistoryToMessageConvertsSystemRole() {
        // Given: System history message
        let history = createMockHistoryMessage(role: "system", content: "System message")

        // When: Convert to message
        let message = coordinator.historyToMessage(history)

        // Then: Should have system role
        XCTAssertEqual(message.role, .system)
    }

    func testHistoryToMessageDefaultsToAssistantForUnknownRole() {
        // Given: Unknown role
        let history = createMockHistoryMessage(role: "unknown", content: "Content")

        // When: Convert to message
        let message = coordinator.historyToMessage(history)

        // Then: Should default to assistant
        XCTAssertEqual(message.role, .assistant)
    }

    // MARK: - Helpers

    private func createMockHistoryMessage(role: String, content: String) -> HistoryMessage {
        // Decode from JSON since HistoryMessage is Decodable only
        let json = """
        {
            "id": "msg_\(UUID().uuidString)",
            "role": "\(role)",
            "content": "\(content)",
            "timestamp": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(HistoryMessage.self, from: json)
    }

    private func createMockTaskListResult(count: Int) -> TaskListResult {
        let json = """
        {
            "tasks": \(count > 0 ? "[{\"id\": \"1\", \"title\": \"Test\", \"status\": \"pending\", \"priority\": \"medium\", \"source\": \"agent\", \"tags\": [], \"createdAt\": \"2024-01-01T00:00:00Z\", \"updatedAt\": \"2024-01-01T00:00:00Z\"}]" : "[]"),
            "total": \(count)
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TaskListResult.self, from: json)
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

// MARK: - Test Tool Call Helper

/// Test-specific struct to configure tool calls (since CurrentTurnToolCall is Decodable only)
struct TestToolCall {
    let toolCallId: String
    let toolName: String
    let status: String
    let result: String?
    let isError: Bool?
    let startedAt: String
    let completedAt: String?
}

// MARK: - Mock Context

/// Mock implementation of ConnectionContext for testing
@MainActor
final class MockConnectionContext: ConnectionContext {
    // MARK: - State
    var sessionId: String = "test-session"
    var agentPhase: AgentPhase = .idle
    var shouldDismiss: Bool = false
    var isConnected: Bool = false

    // MARK: - Tracking for Assertions
    var connectCalled = false
    var disconnectCalled = false
    var resumeSessionCalled = false
    var lastResumeSessionId: String?
    var getAgentStateCalled = false
    var listTasksCalled = false
    var updateTasksCalled = false
    var lastTasksCount: Int = 0
    var setSessionProcessingCalled = false
    var lastSessionProcessingValue: Bool?
    var showErrorAlertCalled = false
    var appendCatchingUpMessageCalled = false
    var processCatchUpContentCalled = false
    var lastCatchUpText: String?
    var lastCatchUpToolCalls: [CurrentTurnToolCall]?

    // MARK: - Test Configuration
    var connectWillSucceed = true
    var resumeSessionError: Error?
    var getAgentStateShouldFail = false
    var agentStateIsRunning = false
    var agentStateCurrentTurnText: String?
    var agentStateToolCalls: [TestToolCall] = []
    var listTasksShouldFail = false
    var tasksResult: TaskListResult = {
        let json = """
        {"tasks": [], "total": 0}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TaskListResult.self, from: json)
    }()

    // MARK: - Protocol Methods

    func connect() async {
        connectCalled = true
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
        if let error = resumeSessionError {
            throw error
        }
    }

    func getAgentState(sessionId: String) async throws -> AgentStateResult {
        getAgentStateCalled = true
        if getAgentStateShouldFail {
            throw ConnectionTestError.generic
        }
        // Build tool calls JSON manually since CurrentTurnToolCall is not Encodable
        let toolCallsJson: String
        if agentStateToolCalls.isEmpty {
            toolCallsJson = "null"
        } else {
            let toolCallJsons = agentStateToolCalls.map { tc in
                """
                {
                    "toolCallId": "\(tc.toolCallId)",
                    "toolName": "\(tc.toolName)",
                    "status": "\(tc.status)",
                    "result": \(tc.result.map { "\"\($0)\"" } ?? "null"),
                    "isError": \(tc.isError ?? false),
                    "startedAt": "\(tc.startedAt)",
                    "completedAt": \(tc.completedAt.map { "\"\($0)\"" } ?? "null")
                }
                """
            }
            toolCallsJson = "[\(toolCallJsons.joined(separator: ","))]"
        }
        let currentTurnTextJson = agentStateCurrentTurnText.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
            "isRunning": \(agentStateIsRunning),
            "currentTurn": 0,
            "messageCount": 0,
            "model": "test-model",
            "currentTurnText": \(currentTurnTextJson),
            "currentTurnToolCalls": \(toolCallsJson)
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(AgentStateResult.self, from: json)
    }

    func listTasks() async throws -> TaskListResult {
        listTasksCalled = true
        if listTasksShouldFail {
            throw ConnectionTestError.generic
        }
        return tasksResult
    }

    func updateTasks(_ tasks: [RpcTask]) {
        updateTasksCalled = true
        lastTasksCount = tasks.count
    }

    func setSessionProcessing(_ isProcessing: Bool) {
        setSessionProcessingCalled = true
        lastSessionProcessingValue = isProcessing
    }

    func appendCatchingUpMessage() -> UUID {
        appendCatchingUpMessageCalled = true
        return UUID()
    }

    func processCatchUpContent(accumulatedText: String, toolCalls: [CurrentTurnToolCall], contentSequence: [ContentSequenceItem]?) async {
        processCatchUpContentCalled = true
        lastCatchUpText = accumulatedText
        lastCatchUpToolCalls = toolCalls
    }

    var removeCatchingUpMessageCalled = false

    func removeCatchingUpMessage() {
        removeCatchingUpMessageCalled = true
    }

    func showError(_ message: String) {
        showErrorAlertCalled = true
    }

    // MARK: - Logging (no-op for tests)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
