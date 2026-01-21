import XCTest
@testable import TronMobile

/// Tests for RPC Client types and data structures
/// Note: Full integration tests require actual server connection.
/// These tests focus on the RPC error types and connection state.
@MainActor
final class RPCClientErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertEqual(
            RPCClientError.noActiveSession.errorDescription,
            "No active session"
        )
        XCTAssertEqual(
            RPCClientError.invalidURL.errorDescription,
            "Invalid server URL"
        )
        XCTAssertEqual(
            RPCClientError.connectionNotEstablished.errorDescription,
            "Connection not established"
        )
    }

}

// MARK: - Connection State Tests

@MainActor
final class ConnectionStateTests: XCTestCase {

    func testConnectionStateIsConnected() {
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertFalse(ConnectionState.connecting.isConnected)
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.reconnecting(attempt: 1).isConnected)
        XCTAssertFalse(ConnectionState.failed(reason: "Test error").isConnected)
    }

    func testConnectionStateDisplayText() {
        XCTAssertEqual(ConnectionState.disconnected.displayText, "Disconnected")
        XCTAssertEqual(ConnectionState.connecting.displayText, "Connecting...")
        XCTAssertEqual(ConnectionState.connected.displayText, "Connected")
        XCTAssertTrue(ConnectionState.reconnecting(attempt: 2).displayText.contains("Reconnecting"))
        XCTAssertTrue(ConnectionState.failed(reason: "Network error").displayText.contains("Failed"))
    }

    func testConnectionStateEquality() {
        XCTAssertEqual(ConnectionState.disconnected, ConnectionState.disconnected)
        XCTAssertEqual(ConnectionState.connected, ConnectionState.connected)
        XCTAssertNotEqual(ConnectionState.disconnected, ConnectionState.connected)
    }
}

// MARK: - Model Info Tests

@MainActor
final class ModelInfoTests: XCTestCase {

    func testModelInfoCreation() {
        let model = createTestModelInfo(id: "claude-opus-4-5-20251101", name: "Opus 4.5")
        XCTAssertEqual(model.id, "claude-opus-4-5-20251101")
        XCTAssertEqual(model.name, "Opus 4.5")
    }

    func testModelInfoContextWindow() {
        let model = createTestModelInfo(
            id: "claude-sonnet-4-20250514",
            name: "Sonnet 4",
            contextWindow: 200_000
        )
        XCTAssertEqual(model.contextWindow, 200_000)
    }

    func testModelInfoIdentifiable() {
        let model = createTestModelInfo(id: "test-model-123", name: "Test Model")
        XCTAssertEqual(model.id, "test-model-123")
    }

    // MARK: - Helper

    private func createTestModelInfo(
        id: String,
        name: String,
        contextWindow: Int = 200_000
    ) -> ModelInfo {
        return ModelInfo(
            id: id,
            name: name,
            provider: "anthropic",
            contextWindow: contextWindow,
            maxOutputTokens: nil,
            supportsThinking: nil,
            supportsImages: nil,
            tier: nil,
            isLegacy: nil,
            supportsReasoning: nil,
            reasoningLevels: nil,
            defaultReasoningLevel: nil,
            thinkingLevel: nil,
            supportedThinkingLevels: nil
        )
    }
}
