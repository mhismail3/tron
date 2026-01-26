import XCTest
@testable import TronMobile

/// Tests for RPCTransport extension helper methods.
/// These helpers eliminate boilerplate guard patterns across RPC clients.
@MainActor
final class RPCTransportHelpersTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Creates a WebSocketService for testing (not connected, just for identity checks)
    private func createTestWebSocket() -> WebSocketService {
        WebSocketService(serverURL: URL(string: "ws://localhost:8080")!)
    }

    // MARK: - requireConnection Tests

    func testRequireConnection_WhenWebSocketAvailable_ReturnsWebSocket() throws {
        // Given
        let webSocket = createTestWebSocket()
        let transport = TestRPCTransport(webSocket: webSocket)

        // When
        let result = try transport.requireConnection()

        // Then
        XCTAssertTrue(result === webSocket, "Should return the same WebSocket instance")
    }

    func testRequireConnection_WhenWebSocketNil_ThrowsConnectionNotEstablished() {
        // Given
        let transport = TestRPCTransport(webSocket: nil)

        // When/Then
        XCTAssertThrowsError(try transport.requireConnection()) { error in
            guard let rpcError = error as? RPCClientError else {
                XCTFail("Expected RPCClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, RPCClientError.connectionNotEstablished)
        }
    }

    // MARK: - requireSession Tests

    func testRequireSession_WhenWebSocketAndSessionAvailable_ReturnsTuple() throws {
        // Given
        let webSocket = createTestWebSocket()
        let sessionId = "test-session-123"
        let transport = TestRPCTransport(webSocket: webSocket, currentSessionId: sessionId)

        // When
        let (ws, sid) = try transport.requireSession()

        // Then
        XCTAssertTrue(ws === webSocket, "Should return the same WebSocket instance")
        XCTAssertEqual(sid, sessionId, "Should return the correct session ID")
    }

    func testRequireSession_WhenWebSocketNil_ThrowsNoActiveSession() {
        // Given
        let transport = TestRPCTransport(webSocket: nil, currentSessionId: "test-session")

        // When/Then
        XCTAssertThrowsError(try transport.requireSession()) { error in
            guard let rpcError = error as? RPCClientError else {
                XCTFail("Expected RPCClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, RPCClientError.noActiveSession)
        }
    }

    func testRequireSession_WhenSessionNil_ThrowsNoActiveSession() {
        // Given
        let webSocket = createTestWebSocket()
        let transport = TestRPCTransport(webSocket: webSocket, currentSessionId: nil)

        // When/Then
        XCTAssertThrowsError(try transport.requireSession()) { error in
            guard let rpcError = error as? RPCClientError else {
                XCTFail("Expected RPCClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, RPCClientError.noActiveSession)
        }
    }

    func testRequireSession_WhenBothNil_ThrowsNoActiveSession() {
        // Given
        let transport = TestRPCTransport(webSocket: nil, currentSessionId: nil)

        // When/Then
        XCTAssertThrowsError(try transport.requireSession()) { error in
            guard let rpcError = error as? RPCClientError else {
                XCTFail("Expected RPCClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, RPCClientError.noActiveSession)
        }
    }

    // MARK: - Error Description Tests

    func testConnectionNotEstablishedErrorDescription() {
        let error = RPCClientError.connectionNotEstablished
        XCTAssertEqual(error.errorDescription, "Connection not established")
    }

    func testNoActiveSessionErrorDescription() {
        let error = RPCClientError.noActiveSession
        XCTAssertEqual(error.errorDescription, "No active session")
    }
}

// MARK: - Test Transport

/// Test implementation of RPCTransport for unit testing helper methods
@MainActor
final class TestRPCTransport: RPCTransport {
    private(set) var webSocket: WebSocketService?
    private(set) var currentSessionId: String?
    private(set) var currentModel: String = "claude-sonnet-4-20250514"
    private(set) var serverOrigin: String = "localhost:8080"

    init(webSocket: WebSocketService? = nil, currentSessionId: String? = nil) {
        self.webSocket = webSocket
        self.currentSessionId = currentSessionId
    }

    func setCurrentSessionId(_ id: String?) {
        currentSessionId = id
    }

    func setCurrentModel(_ model: String) {
        currentModel = model
    }
}
