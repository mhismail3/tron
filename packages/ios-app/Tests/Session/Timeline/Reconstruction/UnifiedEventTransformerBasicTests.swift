import XCTest
@testable import TronMobile

final class UnifiedEventTransformerBasicTests: UnifiedEventTransformerTestCase {
    // MARK: - User Message Tests

    func testTransformUserMessage() {
        let event = rawEvent(
            type: "message.user",
            payload: [
                "content": AnyCodable("Hello, Claude!")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .user)

        if case .text(let text) = message?.content {
            XCTAssertEqual(text, "Hello, Claude!")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testTransformUserMessageWithoutTurnMatchesProductionWirePayload() {
        // `session::reconstruct` returns live prompt user messages
        // with content-only payloads. This is the regression guard for the
        // resume bug where every user bubble disappeared.
        let event = RawEvent(
            id: "user-without-turn",
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: "message.user",
            timestamp: timestamp(),
            sequence: 1,
            payload: ["content": AnyCodable("Persisted without a turn")]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .user)
        if case .text(let text) = message?.content {
            XCTAssertEqual(text, "Persisted without a turn")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testTransformUserMessageWithContentBlocks() {
        // User messages can have content blocks (images, etc.)
        let event = rawEvent(
            type: "message.user",
            payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Look at this image"],
                    ["type": "image", "source": ["type": "base64", "data": "..."]]
                ])
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .user)
    }

    // MARK: - Assistant Message Tests

    func testTransformAssistantMessage() {
        let event = rawEvent(
            type: "message.assistant",
            payload: [
                "content": AnyCodable([["type": "text", "text": "Hello! How can I help?"] as [String: Any]]),
                "model": AnyCodable("claude-sonnet-4-20250514"),
                "turn": AnyCodable(1),
                "latency": AnyCodable(1500)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .text(let text) = message?.content {
            XCTAssertEqual(text, "Hello! How can I help?")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testTransformAssistantMessageWithContentBlocks() {
        let event = rawEvent(
            type: "message.assistant",
            payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me help with that."],
                    ["type": "thinking", "thinking": "Processing the request..."]
                ]),
                "model": AnyCodable("claude-sonnet-4"),
                "turn": AnyCodable(1)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)
    }

    // MARK: - System Message Tests

    func testTransformSystemMessage() {
        let event = rawEvent(
            type: "message.system",
            payload: [
                "content": AnyCodable("Context has been compacted."),
                "source": AnyCodable("compaction")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .system)
    }

    // MARK: - Capability Call Tests

    func testTransformCapabilityInvocation() {
        let event = rawEvent(
            type: "capability.invocation.started",
            payload: [
                "invocationId": AnyCodable("call_123"),
                "modelPrimitiveName": AnyCodable("execute"),
                "arguments": AnyCodable(["file_path": "/src/main.ts"]),
                "turn": AnyCodable(1)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .capabilityInvocation(let invocation) = message?.content {
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation.id, "call_123")
        } else {
            XCTFail("Expected capability invocation content")
        }
    }

    // MARK: - Capability Result Tests

    func testTransformCapabilityResult() {
        let event = rawEvent(
            type: "capability.invocation.completed",
            payload: [
                "invocationId": AnyCodable("call_123"),
                "content": AnyCodable("File contents here..."),
                "isError": AnyCodable(false),
                "duration": AnyCodable(150)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .capability)

        if case .capabilityResult(let result) = message?.content {
            XCTAssertEqual(result.id, "call_123")
            XCTAssertFalse(result.isError)
        } else {
            XCTFail("Expected capability result content")
        }
    }

    func testTransformCapabilityResultWithError() {
        let event = rawEvent(
            type: "capability.invocation.completed",
            payload: [
                "invocationId": AnyCodable("call_456"),
                "content": AnyCodable("File not found"),
                "isError": AnyCodable(true),
                "duration": AnyCodable(42)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)

        if case .capabilityResult(let result) = message?.content {
            XCTAssertTrue(result.isError)
        } else {
            XCTFail("Expected capability result content")
        }
    }

    // MARK: - Model Switch Tests

    func testTransformModelSwitch() {
        let event = rawEvent(
            type: "config.model_switch",
            payload: [
                "previousModel": AnyCodable("claude-sonnet-4"),
                "newModel": AnyCodable("claude-opus-4"),
                "reason": AnyCodable("User requested")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .system)

        guard let content = message?.content else {
            XCTFail("Expected content")
            return
        }
        switch content {
        case .systemEvent(.modelChange(let from, let to)):
            // Transformer humanizes model names for display
            XCTAssertEqual(from, "Sonnet 4")
            XCTAssertEqual(to, "Opus 4")
        default:
            XCTFail("Expected systemEvent(.modelChange) content, got \(content)")
        }
    }

    // MARK: - Error Event Tests

    func testTransformAgentError() {
        let event = rawEvent(
            type: "error.agent",
            payload: [
                "error": AnyCodable("Maximum context length exceeded"),
                "code": AnyCodable("CONTEXT_OVERFLOW"),
                "recoverable": AnyCodable(false)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .error(let text) = message?.content {
            XCTAssertTrue(text.contains("CONTEXT_OVERFLOW"))
            XCTAssertTrue(text.contains("Maximum context length exceeded"))
        } else {
            XCTFail("Expected error content")
        }
    }

    func testTransformCapabilityError() {
        let event = rawEvent(
            type: "error.capability",
            payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("call_789"),
                "error": AnyCodable("Command timed out"),
                "code": AnyCodable("TIMEOUT")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .error(let text) = message?.content {
            XCTAssertTrue(text.contains("execute"))
            XCTAssertTrue(text.contains("Command timed out"))
        } else {
            XCTFail("Expected error content")
        }
    }

    func testTransformProviderError() {
        // I6 scorched-earth: category is required on error.provider.
        // The handler renders every well-formed event as a system-role
        // provider-error pill — the old assistant-role plain-text fallback
        // is gone.
        let event = rawEvent(
            type: "error.provider",
            payload: [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("Rate limit exceeded"),
                "category": AnyCodable("rate_limit"),
                "retryable": AnyCodable(true),
                "retryAfter": AnyCodable(5000)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .system)

        if case .systemEvent(.providerError(let data)) = message?.content {
            XCTAssertEqual(data.provider, "anthropic")
            XCTAssertEqual(data.message, "Rate limit exceeded")
            XCTAssertEqual(data.category, "rate_limit")
            XCTAssertTrue(data.retryable)
        } else {
            XCTFail("Expected provider-error pill content, got \(String(describing: message?.content))")
        }
    }

    func testTransformProviderError_missingCategoryDropsEvent() {
        // Regression guard: the old code path silently fell back to a plain
        // assistant-role error. Strict decoding drops the event instead.
        let event = rawEvent(
            type: "error.provider",
            payload: [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("Rate limit exceeded"),
                "retryable": AnyCodable(true)
            ]
        )
        XCTAssertNil(UnifiedEventTransformer.transformPersistedEvent(event))
    }
}
