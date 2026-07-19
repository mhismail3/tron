import XCTest
@testable import TronMobile

final class EventPluginTests: XCTestCase {
    private let registry = EventRegistry()

    // MARK: - Protocol Conformance Tests

    func testAllPluginsConformToProtocol() {
        // Verify that all plugins have a non-empty event type
        registry.registerAll()
        XCTAssertGreaterThan(registry.pluginCount, 0)
    }

    func testEventTypesAreUnique() {
        registry.registerAll()
        let types = registry.registeredTypes
        let uniqueTypes = Set(types)
        XCTAssertEqual(types.count, uniqueTypes.count, "Event types must be unique")
    }

    func testAllPluginsHaveNonEmptyEventType() {
        // Test a sample of plugins
        XCTAssertFalse(TextDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(ThinkingStartPlugin.eventType.isEmpty)
        XCTAssertFalse(ThinkingDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(ThinkingEndPlugin.eventType.isEmpty)
        XCTAssertFalse(CapabilityInvocationBatchPlugin.eventType.isEmpty)
        XCTAssertFalse(CapabilityInvocationArgumentsDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(CapabilityInvocationStartedPlugin.eventType.isEmpty)
        XCTAssertFalse(CapabilityInvocationCompletedPlugin.eventType.isEmpty)
        XCTAssertFalse(TurnStartPlugin.eventType.isEmpty)
        XCTAssertFalse(TurnEndPlugin.eventType.isEmpty)
        XCTAssertFalse(AgentStartPlugin.eventType.isEmpty)
        XCTAssertFalse(AgentErrorPlugin.eventType.isEmpty)
        XCTAssertFalse(AgentInterruptedPlugin.eventType.isEmpty)
        XCTAssertFalse(AgentRetryPlugin.eventType.isEmpty)
        XCTAssertFalse(CompletePlugin.eventType.isEmpty)
        XCTAssertFalse(AgentResponseCompletePlugin.eventType.isEmpty)
        XCTAssertFalse(ContextWarningPlugin.eventType.isEmpty)
        XCTAssertFalse(SessionForkedPlugin.eventType.isEmpty)
        XCTAssertFalse(ErrorPlugin.eventType.isEmpty)
    }

    func testErrorPluginUsesCurrentServerEventType() {
        XCTAssertEqual(ErrorPlugin.eventType, "error")
    }

    // MARK: - Registry Tests

    func testRegisterPlugin() {
        registry.register(TextDeltaPlugin.self)
        XCTAssertTrue(registry.hasPlugin(for: "agent.text_delta"))
        XCTAssertEqual(registry.pluginCount, 1)
    }

    func testParseKnownEventType() {
        registry.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "delta": "Hello, world!"
            }
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "agent.text_delta", data: json)
        XCTAssertNotNil(result)

        if case .plugin(let type, _, let sessionId, _, let transform) = result {
            XCTAssertEqual(type, "agent.text_delta")
            XCTAssertEqual(sessionId, "session-123")

            let eventResult = transform()
            XCTAssertNotNil(eventResult)
            if let textResult = eventResult as? TextDeltaPlugin.Result {
                XCTAssertEqual(textResult.delta, "Hello, world!")
            } else {
                XCTFail("Expected TextDeltaPlugin.Result")
            }
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testParseErrorEventPreservesCanonicalFailure() {
        registry.register(ErrorPlugin.self)

        let json = """
        {
            "type": "error",
            "sessionId": "session-123",
            "timestamp": "2026-06-09T10:00:00Z",
            "data": {
                "error": "top-level",
                "code": "TOP_LEVEL",
                "details": {
                    "failure": {
                        "code": "PROVIDER_RATE_LIMITED",
                        "category": "rate_limit",
                        "message": "canonical",
                        "retryable": true,
                        "recoverable": true,
                        "origin": "model_provider",
                        "provider": "anthropic"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let parsed = registry.parse(type: "error", data: json)

        guard case .plugin(_, _, _, _, let transform) = parsed,
              let result = transform() as? ErrorPlugin.Result else {
            XCTFail("expected ErrorPlugin.Result")
            return
        }
        XCTAssertEqual(result.code, "PROVIDER_RATE_LIMITED")
        XCTAssertEqual(result.message, "canonical")
        XCTAssertEqual(result.category, "rate_limit")
        XCTAssertEqual(result.provider, "anthropic")
        XCTAssertEqual(result.failure?.origin, "model_provider")
    }

    func testParseErrorEventWithoutCanonicalFailureDropsTransform() {
        registry.register(ErrorPlugin.self)

        let json = """
        {
            "type": "error",
            "data": {
                "error": "top-level only",
                "code": "TOP_LEVEL"
            }
        }
        """.data(using: .utf8)!

        let parsed = registry.parse(type: "error", data: json)

        guard case .plugin(_, _, _, _, let transform) = parsed else {
            XCTFail("expected plugin parse")
            return
        }
        XCTAssertNil(transform())
    }

    func testParseUnknownEventType() {
        registry.registerAll()

        let json = """
        {"type": "some.unknown.event"}
        """.data(using: .utf8)!

        let result = registry.parse(type: "some.unknown.event", data: json)

        if case .unknown(let type) = result {
            XCTAssertEqual(type, "some.unknown.event")
        } else {
            XCTFail("Expected .unknown case")
        }
    }

    func testSessionIdExtraction() {
        registry.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-456",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "agent.text_delta", data: json)
        XCTAssertEqual(result?.sessionId, "session-456")
    }

    func testSessionIdNilWhenMissing() {
        registry.register(ConnectedPlugin.self)

        let json = """
        {
            "type": "connection.established",
            "data": { "serverId": "server-1" }
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "connection.established", data: json)
        XCTAssertNil(result?.sessionId)
    }

    func testMatchesSession() {
        registry.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-789",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "agent.text_delta", data: json)!

        XCTAssertTrue(result.matchesSession("session-789"))
        XCTAssertFalse(result.matchesSession("other-session"))
        XCTAssertFalse(result.matchesSession(nil))
    }

    func testMatchesSessionGlobalEvent() {
        registry.register(ConnectedPlugin.self)

        let json = """
        {
            "type": "connection.established",
            "data": {}
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "connection.established", data: json)!

        // Global events (no sessionId) match any session
        XCTAssertTrue(result.matchesSession("any-session"))
        XCTAssertTrue(result.matchesSession(nil))
    }

    func testRegisteredPluginCount() {
        registry.registerAll()
        // Should have all 38+ plugins registered
        XCTAssertGreaterThanOrEqual(registry.pluginCount, 38)
        XCTAssertTrue(registry.hasPlugin(for: "agent.start"))
        XCTAssertTrue(registry.hasPlugin(for: "agent.error"))
        XCTAssertTrue(registry.hasPlugin(for: "agent.interrupted"))
        XCTAssertTrue(registry.hasPlugin(for: "agent.retry"))
        XCTAssertTrue(registry.hasPlugin(for: "context.warning"))
        XCTAssertTrue(registry.hasPlugin(for: "session.forked"))
        XCTAssertTrue(registry.hasPlugin(for: "agent.thinking_start"))
        XCTAssertTrue(registry.hasPlugin(for: "agent.response_complete"))
        XCTAssertTrue(registry.hasPlugin(for: "agent.thinking_end"))
        XCTAssertTrue(registry.hasPlugin(for: "capability.invocation.batch"))
        XCTAssertTrue(registry.hasPlugin(for: "capability.invocation.arguments_delta"))
    }

    func testSessionScopedMarkerPluginsParseWithoutUiResult() {
        registry.registerAll()

        for type in [
            "agent.start",
            "agent.interrupted",
            "agent.retry",
            "context.warning",
            "session.forked",
            "agent.thinking_start",
            "capability.invocation.batch",
            "capability.invocation.arguments_delta"
        ] {
            let json = """
            {
                "type": "\(type)",
                "sessionId": "session-marker",
                "sequence": 42,
                "timestamp": "2026-06-29T10:00:00Z",
                "data": {"ignored": true}
            }
            """.data(using: .utf8)!

            let result = registry.parse(type: type, data: json)
            XCTAssertEqual(result?.eventType, type)
            XCTAssertEqual(result?.sessionId, "session-marker")
            XCTAssertEqual(result?.sequence, 42)
            XCTAssertNil(result?.getResult())
        }
    }

    func testThinkingEndPluginParsesAuthoritativeSnapshot() {
        registry.registerAll()
        let json = """
        {
            "type": "agent.thinking_end",
            "sessionId": "session-thinking",
            "sequence": 43,
            "timestamp": "2026-06-29T10:00:01Z",
            "data": {"thinking": "Final thinking text"}
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "agent.thinking_end", data: json)
        let pluginResult = result?.getResult() as? ThinkingEndPlugin.Result

        XCTAssertEqual(result?.eventType, "agent.thinking_end")
        XCTAssertEqual(pluginResult?.thinking, "Final thinking text")
        XCTAssertEqual(pluginResult?.kind, .thinking)
    }

    func testThinkingPluginsParseReasoningSummaryKind() {
        registry.registerAll()
        let deltaJson = """
        {
            "type": "agent.thinking_delta",
            "sessionId": "session-thinking",
            "sequence": 44,
            "timestamp": "2026-06-29T10:00:02Z",
            "data": {"delta": "Summary", "kind": "reasoning_summary"}
        }
        """.data(using: .utf8)!
        let endJson = """
        {
            "type": "agent.thinking_end",
            "sessionId": "session-thinking",
            "sequence": 45,
            "timestamp": "2026-06-29T10:00:03Z",
            "data": {"thinking": "Summary", "kind": "reasoning_summary"}
        }
        """.data(using: .utf8)!

        let deltaResult = registry.parse(type: "agent.thinking_delta", data: deltaJson)?
            .getResult() as? ThinkingDeltaPlugin.Result
        let endResult = registry.parse(type: "agent.thinking_end", data: endJson)?
            .getResult() as? ThinkingEndPlugin.Result

        XCTAssertEqual(deltaResult?.kind, .reasoningSummary)
        XCTAssertEqual(endResult?.kind, .reasoningSummary)
    }

    // MARK: - Session Archive/Unarchive Plugin Tests

    func testSessionArchivedPlugin_parsesFromTopLevelSessionId() {
        registry.register(SessionArchivedPlugin.self)

        let json = """
        {
            "type": "session.archived",
            "sessionId": "sess-123",
            "timestamp": "2026-02-12T00:00:00Z",
            "data": {"sessionId": "sess-123"}
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "session.archived", data: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, "sess-123")

        if case .plugin(let type, _, _, _, let transform) = result {
            XCTAssertEqual(type, "session.archived")
            let eventResult = transform() as? SessionArchivedPlugin.Result
            XCTAssertEqual(eventResult?.sessionId, "sess-123")
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testSessionArchivedPlugin_parsesFromDataSessionId() {
        registry.register(SessionArchivedPlugin.self)

        let json = """
        {
            "type": "session.archived",
            "data": {"sessionId": "sess-456"}
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "session.archived", data: json)
        if case .plugin(_, _, _, _, let transform) = result {
            let eventResult = transform() as? SessionArchivedPlugin.Result
            XCTAssertEqual(eventResult?.sessionId, "sess-456")
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testSessionUnarchivedPlugin_parses() {
        registry.register(SessionUnarchivedPlugin.self)

        let json = """
        {
            "type": "session.unarchived",
            "sessionId": "sess-789",
            "data": {"sessionId": "sess-789"}
        }
        """.data(using: .utf8)!

        let result = registry.parse(type: "session.unarchived", data: json)
        XCTAssertNotNil(result)

        if case .plugin(let type, _, _, _, let transform) = result {
            XCTAssertEqual(type, "session.unarchived")
            let eventResult = transform() as? SessionUnarchivedPlugin.Result
            XCTAssertEqual(eventResult?.sessionId, "sess-789")
        } else {
            XCTFail("Expected .plugin case")
        }
    }
}
