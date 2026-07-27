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

@MainActor
final class EnginePendingRequestLifecycleTests: XCTestCase {
    func testCancellationImmediatelyRetiresOnlyTheTargetRequest() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        var installed = false
        let waiter = Task { @MainActor in
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.pendingRequests["cancel-me"] = continuation
                connection.timeoutTasks["cancel-me"] = Task {
                    try? await Task.sleep(for: .seconds(60))
                }
                installed = true
            }
        }
        while !installed {
            await Task.yield()
        }

        connection.cancelPendingRequest(id: "cancel-me")

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(connection.pendingRequests.isEmpty)
        XCTAssertTrue(connection.timeoutTasks.isEmpty)
    }

    func testInboundResponseRoutingDoesNotMaterializeResultPayload() {
        let data = Data(
            #"{"type":"response","id":"response-1","ok":true,"result":{"body":"private"}}"#.utf8
        )

        switch EngineConnection.parseInboundMessage(data) {
        case .response(let id):
            XCTAssertEqual(id, "response-1")
        default:
            XCTFail("Expected correlated response routing")
        }
    }

    func testInboundEventRoutingDecodesNeutralPayloadOnce() throws {
        let data = Data(
            #"{"type":"event","topic":"events.session","subscriptionId":"sub-1","cursor":7,"event":{"type":"agent.ready","sessionId":"session-1","timestamp":"2026-07-26T00:00:00Z"}}"#.utf8
        )

        switch EngineConnection.parseInboundMessage(data) {
        case .event(let delivery):
            XCTAssertEqual(delivery.subscriptionId, "sub-1")
            XCTAssertEqual(delivery.cursor, EngineStreamCursor(rawValue: 7))
            XCTAssertEqual(delivery.event.type, "agent.ready")
            XCTAssertEqual(delivery.event.sessionId, "session-1")
            let reconstructed = try JSONDecoder().decode(
                ServerEventPayload.self,
                from: delivery.eventData
            )
            XCTAssertEqual(reconstructed, delivery.event)
        default:
            XCTFail("Expected neutral event routing")
        }
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
