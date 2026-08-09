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
        var startedRequestIds: Set<String> = []
        let cancelled = Task { @MainActor in
            try await connection.awaitPendingResponse(
                id: "cancel-me",
                operation: "test.cancel",
                timeout: 60
            ) {
                startedRequestIds.insert("cancel-me")
            }
        }
        let survivor = Task { @MainActor in
            try await connection.awaitPendingResponse(
                id: "keep-me",
                operation: "test.keep",
                timeout: 60
            ) {
                startedRequestIds.insert("keep-me")
            }
        }
        while startedRequestIds.count < 2 {
            await Task.yield()
        }

        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(Set(connection.pendingRequests.keys), ["keep-me"])

        let survivorData = Data(#"{"id":"keep-me","ok":true}"#.utf8)
        XCTAssertTrue(
            connection.finishPendingRequest(
                id: "keep-me",
                result: .success(survivorData)
            )
        )
        let returned = try? await survivor.value
        XCTAssertEqual(returned, survivorData)
        XCTAssertTrue(connection.pendingRequests.isEmpty)

        // A server response that was already in flight after caller
        // cancellation is ignored instead of double-resuming the continuation.
        await connection.handleMessage(
            Data(#"{"id":"cancel-me","ok":true}"#.utf8)
        )
        XCTAssertTrue(connection.pendingRequests.isEmpty)
    }

    func testRequestTimeoutLeavesSharedConnectionAndOtherRequestAlive() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        var startedRequestIds: Set<String> = []

        let expiring = Task { @MainActor in
            try await connection.awaitPendingResponse(
                id: "expire-me",
                operation: "test.timeout",
                timeout: 0.02
            ) {
                startedRequestIds.insert("expire-me")
            }
        }
        let survivor = Task { @MainActor in
            try await connection.awaitPendingResponse(
                id: "survive-timeout",
                operation: "test.survivor",
                timeout: 60
            ) {
                startedRequestIds.insert("survive-timeout")
            }
        }
        while startedRequestIds.count < 2 {
            await Task.yield()
        }

        do {
            _ = try await expiring.value
            XCTFail("Expected request-local timeout")
        } catch EngineConnectionError.timeout {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(connection.isConnectedFlag)
        XCTAssertEqual(connection.connectionState, .connected)
        XCTAssertEqual(
            Set(connection.pendingRequests.keys),
            ["survive-timeout"]
        )

        let survivorData = Data(#"{"id":"survive-timeout","ok":true}"#.utf8)
        XCTAssertTrue(
            connection.finishPendingRequest(
                id: "survive-timeout",
                result: .success(survivorData)
            )
        )
        let returned = try? await survivor.value
        XCTAssertEqual(returned, survivorData)
        XCTAssertTrue(connection.pendingRequests.isEmpty)
    }

    func testBackgroundRetirementImmediatelyFailsPendingRequests() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        var didStart = false
        let pending = Task { @MainActor in
            try await connection.awaitPendingResponse(
                id: "backgrounded",
                operation: "session.reconstruct",
                timeout: 60
            ) {
                didStart = true
            }
        }
        while !didStart {
            await Task.yield()
        }

        connection.setBackgroundState(true)

        do {
            _ = try await pending.value
            XCTFail("Expected transport retirement")
        } catch EngineConnectionError.notConnected {
            // Expected: backgrounding resolves the stale RPC immediately.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(connection.pendingRequests.isEmpty)
        XCTAssertEqual(connection.connectionState, .disconnected)
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

    func testInboundTerminalOutputRoutesWithoutCorrelationID() {
        let data = Data(
            #"{"type":"terminal.output","attachmentId":"attach-1","terminalId":"term-1","generation":1,"sequence":7,"dataBase64":"b2sK"}"#.utf8
        )

        switch EngineConnection.parseInboundMessage(data) {
        case .terminal(let frame):
            XCTAssertEqual(frame.attachmentId, "attach-1")
            XCTAssertEqual(frame.sequence, 7)
            XCTAssertEqual(frame.dataBase64, "b2sK")
        default:
            XCTFail("Expected terminal stream routing")
        }
    }

    func testConnectionOwnedFrameDecoderNormalizesTextOffMainActor() async {
        let decoder = EngineInboundFrameDecoder()
        let frame = await decoder.decode(
            text: #"{"id":"response-actor","ok":true,"result":{"body":"private"}}"#
        )

        XCTAssertEqual(frame.wireKind, .text)
        switch frame.message {
        case .response(let id):
            XCTAssertEqual(id, "response-actor")
        default:
            XCTFail("Expected correlated response routing")
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
