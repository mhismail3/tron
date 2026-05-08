import XCTest
@testable import TronMobile

/// Tests for EngineTransport extension helper methods.
/// These helpers eliminate boilerplate guard patterns across engine clients.
@MainActor
final class EngineTransportHelpersTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Creates a EngineConnection for testing (not connected, just for identity checks)
    private func createTestWebSocket() -> EngineConnection {
        EngineConnection(serverURL: URL(string: "ws://localhost:8080")!)
    }

    // MARK: - requireConnection Tests

    func testRequireConnection_WhenWebSocketAvailable_ReturnsWebSocket() throws {
        // Given
        let engineConnection = createTestWebSocket()
        let transport = TestEngineTransport(engineConnection: engineConnection)

        // When
        let result = try transport.requireConnection()

        // Then
        XCTAssertTrue(result === engineConnection, "Should return the same WebSocket instance")
    }

    func testRequireConnection_WhenWebSocketNil_ThrowsConnectionNotEstablished() {
        // Given
        let transport = TestEngineTransport(engineConnection: nil)

        // When/Then
        XCTAssertThrowsError(try transport.requireConnection()) { error in
            guard let rpcError = error as? EngineClientError else {
                XCTFail("Expected EngineClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, EngineClientError.connectionNotEstablished)
        }
    }

    // MARK: - requireSession Tests

    func testRequireSession_WhenWebSocketAndSessionAvailable_ReturnsTuple() throws {
        // Given
        let engineConnection = createTestWebSocket()
        let sessionId = "test-session-123"
        let transport = TestEngineTransport(engineConnection: engineConnection, currentSessionId: sessionId)

        // When
        let (ws, sid) = try transport.requireSession()

        // Then
        XCTAssertTrue(ws === engineConnection, "Should return the same WebSocket instance")
        XCTAssertEqual(sid, sessionId, "Should return the correct session ID")
    }

    func testRequireSession_WhenWebSocketNil_ThrowsNoActiveSession() {
        // Given
        let transport = TestEngineTransport(engineConnection: nil, currentSessionId: "test-session")

        // When/Then
        XCTAssertThrowsError(try transport.requireSession()) { error in
            guard let rpcError = error as? EngineClientError else {
                XCTFail("Expected EngineClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, EngineClientError.noActiveSession)
        }
    }

    func testRequireSession_WhenSessionNil_ThrowsNoActiveSession() {
        // Given
        let engineConnection = createTestWebSocket()
        let transport = TestEngineTransport(engineConnection: engineConnection, currentSessionId: nil)

        // When/Then
        XCTAssertThrowsError(try transport.requireSession()) { error in
            guard let rpcError = error as? EngineClientError else {
                XCTFail("Expected EngineClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, EngineClientError.noActiveSession)
        }
    }

    func testRequireSession_WhenBothNil_ThrowsNoActiveSession() {
        // Given
        let transport = TestEngineTransport(engineConnection: nil, currentSessionId: nil)

        // When/Then
        XCTAssertThrowsError(try transport.requireSession()) { error in
            guard let rpcError = error as? EngineClientError else {
                XCTFail("Expected EngineClientError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(rpcError, EngineClientError.noActiveSession)
        }
    }

    // MARK: - Error Description Tests

    func testConnectionNotEstablishedErrorDescription() {
        let error = EngineClientError.connectionNotEstablished
        XCTAssertEqual(error.errorDescription, "Connection not established")
    }

    func testNoActiveSessionErrorDescription() {
        let error = EngineClientError.noActiveSession
        XCTAssertEqual(error.errorDescription, "No active session")
    }
}

// MARK: - Test Transport

/// Test implementation of EngineTransport for unit testing helper methods
@MainActor
final class TestEngineTransport: EngineTransport {
    private(set) var engineConnection: EngineConnection?
    var connectionState: ConnectionState = .connected
    private(set) var currentSessionId: String?
    private(set) var currentModel: String = "claude-sonnet-4-20250514"
    private(set) var serverOrigin: String = "localhost:8080"

    init(engineConnection: EngineConnection? = nil, currentSessionId: String? = nil, connectionState: ConnectionState = .connected) {
        self.engineConnection = engineConnection
        self.currentSessionId = currentSessionId
        self.connectionState = connectionState
    }

    func setCurrentSessionId(_ id: String?) {
        currentSessionId = id
    }

    func setCurrentModel(_ model: String) {
        currentModel = model
    }

    func invokeRead<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        options: EngineInvocationOptions
    ) async throws -> R {
        _ = try requireConnection()
        throw EngineConnectionError.invalidResponse
    }

    func invokeWrite<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey,
        options: EngineInvocationOptions
    ) async throws -> R {
        _ = try requireConnection()
        throw EngineConnectionError.invalidResponse
    }
}
