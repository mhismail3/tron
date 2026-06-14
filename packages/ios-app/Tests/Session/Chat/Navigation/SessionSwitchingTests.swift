import XCTest
@testable import TronMobile

/// Tests for session switching behavior in ContentView/ChatView
/// Verifies that switching sessions creates fresh ChatViewModel instances
/// with the correct sessionId and clean state.
@MainActor
final class SessionSwitchingTests: XCTestCase {

    // MARK: - ChatViewModel Session Identity Tests

    func testChatViewModelHasCorrectSessionId() {
        // Given: A ChatViewModel created for a specific session
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let sessionId = "test-session-123"

        // When: Creating the ViewModel
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: sessionId)

        // Then: ViewModel should have the correct sessionId
        XCTAssertEqual(viewModel.sessionId, sessionId)
    }

    func testChatViewModelSessionIdIsImmutable() {
        // Given: Two different session IDs
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)

        // When: Creating ViewModels for different sessions
        let viewModel1 = ChatViewModel(engineClient: engineClient, sessionId: "session-A")
        let viewModel2 = ChatViewModel(engineClient: engineClient, sessionId: "session-B")

        // Then: Each ViewModel maintains its own sessionId
        XCTAssertEqual(viewModel1.sessionId, "session-A")
        XCTAssertEqual(viewModel2.sessionId, "session-B")
        XCTAssertNotEqual(viewModel1.sessionId, viewModel2.sessionId)
    }

    func testNewChatViewModelHasEmptyMessages() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        // Then: Messages should start empty
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testNewChatViewModelIsNotProcessing() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        // Then: Should not be processing
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testNewChatViewModelHasDisconnectedState() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        // Then: Connection state should be disconnected
        XCTAssertEqual(viewModel.connectionState, .disconnected)
    }

    func testNewChatViewModelHasEmptyInputState() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        // Then: Input should be empty
        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertTrue(viewModel.attachments.isEmpty)
    }

    // MARK: - Session Independence Tests

    func testMultipleViewModelsHaveIndependentState() {
        // Given: Two ViewModels for different sessions
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)

        let viewModel1 = ChatViewModel(engineClient: engineClient, sessionId: "session-A")
        let viewModel2 = ChatViewModel(engineClient: engineClient, sessionId: "session-B")

        // When: Modifying state on viewModel1
        viewModel1.inputText = "Hello from session A"
        viewModel1.isProcessing = true
        viewModel1.messages.append(ChatMessage(id: UUID(), role: .user, content: .text("Test message")))

        // Then: viewModel2 state should be unaffected
        XCTAssertTrue(viewModel2.inputText.isEmpty)
        XCTAssertFalse(viewModel2.isProcessing)
        XCTAssertTrue(viewModel2.messages.isEmpty)
    }

    func testViewModelsShareConnectionRepository() {
        // Given: Two ViewModels sharing the same transport-backed services
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let services = ChatSessionServices(
            connection: DefaultAppConnectionRepository(client: engineClient),
            events: DefaultSessionEventRepository(client: engineClient),
            sessions: DefaultSessionRepository(sessionClient: engineClient.session),
            agent: DefaultAgentRepository(agentClient: engineClient.agent),
            models: DefaultModelRepository(modelClient: engineClient.model),
            messages: DefaultMessageRepository(messageClient: engineClient.message),
            workerLifecycle: DefaultWorkerLifecycleRepository(client: engineClient.workerLifecycle)
        )

        let viewModel1 = ChatViewModel(services: services, sessionId: "session-A")
        let viewModel2 = ChatViewModel(services: services, sessionId: "session-B")

        // Then: Both should reference the same connection boundary.
        XCTAssertTrue(viewModel1.services.connection === viewModel2.services.connection)
    }
}
