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
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let sessionId = "test-session-123"

        // When: Creating the ViewModel
        let viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: sessionId)

        // Then: ViewModel should have the correct sessionId
        XCTAssertEqual(viewModel.sessionId, sessionId)
    }

    func testChatViewModelSessionIdIsImmutable() {
        // Given: Two different session IDs
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)

        // When: Creating ViewModels for different sessions
        let viewModel1 = ChatViewModel(rpcClient: rpcClient, sessionId: "session-A")
        let viewModel2 = ChatViewModel(rpcClient: rpcClient, sessionId: "session-B")

        // Then: Each ViewModel maintains its own sessionId
        XCTAssertEqual(viewModel1.sessionId, "session-A")
        XCTAssertEqual(viewModel2.sessionId, "session-B")
        XCTAssertNotEqual(viewModel1.sessionId, viewModel2.sessionId)
    }

    func testNewChatViewModelHasEmptyMessages() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")

        // Then: Messages should start empty
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testNewChatViewModelIsNotProcessing() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")

        // Then: Should not be processing
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testNewChatViewModelHasDisconnectedState() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")

        // Then: Connection state should be disconnected
        XCTAssertEqual(viewModel.connectionState, .disconnected)
    }

    func testNewChatViewModelHasCleanBrowserState() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")

        // Then: Browser state should be clean
        XCTAssertNil(viewModel.browserState.browserFrame)
        XCTAssertNil(viewModel.browserState.browserStatus)
        XCTAssertFalse(viewModel.browserState.showBrowserWindow)
    }

    func testNewChatViewModelHasEmptyInputState() {
        // Given: A fresh ChatViewModel
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")

        // Then: Input should be empty
        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertTrue(viewModel.attachments.isEmpty)
    }

    // MARK: - Session Independence Tests

    func testMultipleViewModelsHaveIndependentState() {
        // Given: Two ViewModels for different sessions
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)

        let viewModel1 = ChatViewModel(rpcClient: rpcClient, sessionId: "session-A")
        let viewModel2 = ChatViewModel(rpcClient: rpcClient, sessionId: "session-B")

        // When: Modifying state on viewModel1
        viewModel1.inputText = "Hello from session A"
        viewModel1.isProcessing = true
        viewModel1.messages.append(ChatMessage(id: UUID(), role: .user, content: .text("Test message")))

        // Then: viewModel2 state should be unaffected
        XCTAssertTrue(viewModel2.inputText.isEmpty)
        XCTAssertFalse(viewModel2.isProcessing)
        XCTAssertTrue(viewModel2.messages.isEmpty)
    }

    func testViewModelsShareRPCClient() {
        // Given: Two ViewModels sharing the same RPCClient
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)

        let viewModel1 = ChatViewModel(rpcClient: rpcClient, sessionId: "session-A")
        let viewModel2 = ChatViewModel(rpcClient: rpcClient, sessionId: "session-B")

        // Then: Both should reference the same RPCClient (for efficient connection reuse)
        XCTAssertTrue(viewModel1.rpcClient === viewModel2.rpcClient)
    }
}
