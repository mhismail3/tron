import XCTest
@testable import TronMobile

/// Tests for Engine Client types and data structures
/// Note: Full integration tests require actual server connection.
/// These tests focus on the engine protocol error types and connection state.
@MainActor
final class EngineClientErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertEqual(
            EngineClientError.noActiveSession.errorDescription,
            "No active session"
        )
        XCTAssertEqual(
            EngineClientError.invalidURL.errorDescription,
            "Invalid server URL"
        )
        XCTAssertEqual(
            EngineClientError.connectionNotEstablished.errorDescription,
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
        XCTAssertFalse(ConnectionState.reconnecting(attempt: 1, nextRetrySeconds: 5).isConnected)
        XCTAssertFalse(ConnectionState.failed(reason: "Test error").isConnected)
    }

    func testConnectionStateDisplayText() {
        XCTAssertEqual(ConnectionState.disconnected.displayText, "Disconnected")
        XCTAssertEqual(ConnectionState.connecting.displayText, "Connecting...")
        XCTAssertEqual(ConnectionState.connected.displayText, "Connected")
        XCTAssertTrue(ConnectionState.reconnecting(attempt: 2, nextRetrySeconds: 3).displayText.contains("Reconnecting"))
        XCTAssertTrue(ConnectionState.failed(reason: "Network error").displayText.contains("Failed"))
    }

    func testConnectionStateEquality() {
        XCTAssertEqual(ConnectionState.disconnected, ConnectionState.disconnected)
        XCTAssertEqual(ConnectionState.connected, ConnectionState.connected)
        XCTAssertNotEqual(ConnectionState.disconnected, ConnectionState.connected)
    }
}

// MARK: - Stream Subscription Scope Tests

@MainActor
final class EngineStreamScopeTests: XCTestCase {

    func testSessionEventFiltersUseExplicitSessionScope() {
        let filters = EngineClient.sessionEventFilters(sessionId: "session-123", workspaceId: "workspace-456")

        XCTAssertEqual(filters["sessionId"]?.stringValue, "session-123")
        XCTAssertEqual(filters["workspaceId"]?.stringValue, "workspace-456")
        XCTAssertEqual(
            EngineClient.sessionEventFilterHash(sessionId: "session-123", workspaceId: "workspace-456"),
            "sessionId=session-123;workspaceId=workspace-456"
        )
    }
}

// MARK: - Notification Refresh Tests

@MainActor
final class NotificationStoreConnectionTests: XCTestCase {

    func testRefreshOnlyRunsWhenEngineIsConnected() {
        XCTAssertFalse(NotificationStore.shouldRefreshFromServer(connectionState: .disconnected))
        XCTAssertFalse(NotificationStore.shouldRefreshFromServer(connectionState: .connecting))
        XCTAssertTrue(NotificationStore.shouldRefreshFromServer(connectionState: .connected))
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
        // I8: the five metadata fields (supportsThinking/Images/Documents,
        // tier, isRetiredGeneration) are required — the server emits them
        // unconditionally from every provider registry.
        return ModelInfo(
            id: id,
            name: name,
            provider: "anthropic",
            contextWindow: contextWindow,
            supportsThinking: false,
            supportsImages: false,
            supportsDocuments: false,
            tier: "sonnet",
            isRetiredGeneration: false
        )
    }
}
