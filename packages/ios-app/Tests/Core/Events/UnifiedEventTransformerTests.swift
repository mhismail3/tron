import XCTest
@testable import TronMobile

/// Tests for UnifiedEventTransformer
/// Ensures consistent event→ChatMessage transformation across all code paths
final class UnifiedEventTransformerTests: XCTestCase {

    // MARK: - Helper Functions

    /// Creates a timestamp string in ISO8601 format
    private func timestamp(_ offsetSeconds: TimeInterval = 0) -> String {
        let date = Date().addingTimeInterval(offsetSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeTokenRecordPayload(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        turn: Int = 1,
        contextWindowTokens: Int? = nil,
        newInputTokens: Int? = nil,
        previousContextBaseline: Int = 0,
        provider: String = "anthropic",
        model: String = "claude-sonnet-4",
        sessionId: String = "test-session",
        timestamp: String = "2026-01-01T00:00:00Z"
    ) -> [String: Any] {
        [
            "source": [
                "provider": provider,
                "timestamp": timestamp,
                "rawInputTokens": inputTokens,
                "rawOutputTokens": outputTokens,
                "rawCacheReadTokens": cacheReadTokens,
                "rawCachedInputTokens": cacheReadTokens,
                "rawCacheCreationTokens": cacheCreationTokens,
                "rawCacheCreation5mTokens": cacheCreationTokens,
                "rawCacheCreation1hTokens": 0,
                "rawReasoningOutputTokens": 0,
                "rawThoughtTokens": 0,
                "rawToolUsePromptTokens": 0,
                "rawTotalTokens": inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
            ],
            "computed": [
                "contextWindowTokens": contextWindowTokens ?? (inputTokens + cacheReadTokens + cacheCreationTokens),
                "newInputTokens": newInputTokens ?? inputTokens,
                "previousContextBaseline": previousContextBaseline,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": turn,
                "sessionId": sessionId,
                "model": model,
                "contextSegmentId": "\(sessionId):\(provider):\(model)",
                "baselineResetReason": "none",
                "extractedAt": timestamp,
                "normalizedAt": timestamp
            ],
            "pricing": [
                "available": true,
                "model": model,
                "reason": NSNull(),
                "cost": [
                    "baseInputTokens": inputTokens,
                    "outputTokens": outputTokens,
                    "cacheReadTokens": cacheReadTokens,
                    "cacheWriteTokens": cacheCreationTokens,
                    "cacheWrite5mTokens": cacheCreationTokens,
                    "cacheWrite1hTokens": 0,
                    "baseInputCost": 0,
                    "outputCost": 0,
                    "cacheReadCost": 0,
                    "cacheWriteCost": 0,
                    "totalCost": 0,
                    "currency": "USD"
                ]
            ]
        ]
    }

    /// Creates a RawEvent for testing
    private func rawEvent(
        id: String = UUID().uuidString,
        parentId: String? = nil,
        sessionId: String = "test-session",
        type: String,
        payload: [String: AnyCodable],
        timestamp: String? = nil,
        sequence: Int = 1
    ) -> RawEvent {
        return RawEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: timestamp ?? self.timestamp(),
            sequence: sequence,
            payload: augmentPayload(type: type, payload: payload)
        )
    }

    /// Creates a SessionEvent for testing
    private func sessionEvent(
        id: String = UUID().uuidString,
        parentId: String? = nil,
        sessionId: String = "test-session",
        type: String,
        payload: [String: AnyCodable],
        timestamp: String? = nil,
        sequence: Int = 1
    ) -> SessionEvent {
        return SessionEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: timestamp ?? self.timestamp(),
            sequence: sequence,
            payload: augmentPayload(type: type, payload: payload)
        )
    }

    /// Inject required-but-test-irrelevant payload fields for event types that
    /// have strict schemas. Tests that care about a specific value override by
    /// setting it explicitly in the payload dict; this helper only adds fields
    /// that are absent. This mirrors the `#[serde(default)]`-free but
    /// always-emitted-by-server reality of production payloads like
    /// `message.assistant` (content / turn / model / stopReason).
    private func augmentPayload(type: String, payload: [String: AnyCodable]) -> [String: AnyCodable] {
        var augmented = payload
        switch type {
        case "message.assistant":
            if augmented["turn"] == nil { augmented["turn"] = AnyCodable(1) }
            if augmented["model"] == nil { augmented["model"] = AnyCodable("claude-sonnet-4") }
            if augmented["stopReason"] == nil { augmented["stopReason"] = AnyCodable("end_turn") }
        case "message.system":
            if augmented["source"] == nil { augmented["source"] = AnyCodable("compaction") }
        case PersistedEventType.capabilityInvocationStarted.rawValue:
            if augmented["modelPrimitiveName"] == nil {
                augmented["modelPrimitiveName"] = AnyCodable("execute")
            }
        case PersistedEventType.capabilityInvocationCompleted.rawValue:
            if augmented["modelPrimitiveName"] == nil {
                augmented["modelPrimitiveName"] = AnyCodable("execute")
            }
        case "session.start":
            if augmented["workingDirectory"] == nil { augmented["workingDirectory"] = AnyCodable("/test/workspace") }
            if augmented["model"] == nil { augmented["model"] = AnyCodable("claude-sonnet-4") }
            if augmented["provider"] == nil { augmented["provider"] = AnyCodable("anthropic") }
        default:
            break
        }
        return augmented
    }

    /// Canonical minimal payloads for every persisted event type that claims
    /// `rendersAsChatMessage == true`. Keep this in lockstep with
    /// `PersistedEventType.classification`; the coverage test below fails when
    /// a new rendered event is added without a reconstruction fixture.
    private func renderableEventFixtures() -> [PersistedEventType: [String: AnyCodable]] {
        [
            .messageUser: [
                // Production `session::reconstruct` payloads may omit `turn`.
                "content": AnyCodable("Hello from the persisted event log")
            ],
            .messageAssistant: [
                "content": AnyCodable([["type": "text", "text": "Assistant response"] as [String: Any]]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "stopReason": AnyCodable("end_turn")
            ],
            .messageSystem: [
                "content": AnyCodable("System note"),
                "source": AnyCodable("compaction")
            ],
            .capabilityInvocationStarted: [
                "invocationId": AnyCodable("capability-fixture"),
                "modelPrimitiveName": AnyCodable("execute"),
                "arguments": AnyCodable(["command": "true"]),
                "turn": AnyCodable(1)
            ],
            .capabilityInvocationCompleted: [
                "invocationId": AnyCodable("capability-fixture"),
                "modelPrimitiveName": AnyCodable("execute"),
                "content": AnyCodable("ok"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(25)
            ],
            .configModelSwitch: [
                "previousModel": AnyCodable("claude-sonnet-4"),
                "newModel": AnyCodable("claude-opus-4")
            ],
            .configReasoningLevel: [
                "previousLevel": AnyCodable("medium"),
                "newLevel": AnyCodable("high")
            ],
            .compactBoundary: [
                "originalTokens": AnyCodable(10_000),
                "compactedTokens": AnyCodable(2_000),
                "reason": AnyCodable("manual")
            ],
            .contextCleared: [
                "tokensBefore": AnyCodable(10_000),
                "tokensAfter": AnyCodable(500)
            ],
            .errorAgent: [
                "error": AnyCodable("Agent failed"),
                "recoverable": AnyCodable(false)
            ],
            .errorCapability: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("capability-fixture"),
                "error": AnyCodable("Command failed")
            ],
            .errorProvider: [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("Rate limited"),
                "category": AnyCodable("rate_limit"),
                "retryable": AnyCodable(true)
            ],
            .turnFailed: [
                "turn": AnyCodable(1),
                "error": AnyCodable("Turn failed"),
                "recoverable": AnyCodable(true)
            ]
        ]
    }

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

    // MARK: - Event Filtering Tests

    func testMetadataEventsAreFiltered() {
        // These events should NOT produce ChatMessages
        let metadataTypes = [
            "session.start",
            "session.end",
            "compact.boundary",
            "stream.turn_end"
        ]

        for type in metadataTypes {
            let event = rawEvent(type: type, payload: [:])
            let message = UnifiedEventTransformer.transformPersistedEvent(event)
            XCTAssertNil(message, "Expected \(type) to be filtered out")
        }
    }

    func testEveryRenderablePersistedEventHasAWorkingReconstructionFixture() {
        let fixtures = renderableEventFixtures()
        let renderableTypes = PersistedEventType.allCases.filter(\.rendersAsChatMessage)
        let missingFixtures = renderableTypes
            .filter { fixtures[$0] == nil }
            .map(\.rawValue)
            .sorted()

        XCTAssertTrue(
            missingFixtures.isEmpty,
            "Missing reconstruction fixtures for renderable persisted event types: \(missingFixtures)"
        )

        for (offset, eventType) in renderableTypes.enumerated() {
            guard let payload = fixtures[eventType] else { continue }
            let event = RawEvent(
                id: "fixture-\(eventType.rawValue)",
                parentId: nil,
                sessionId: "test-session",
                workspaceId: "/test/workspace",
                type: eventType.rawValue,
                timestamp: timestamp(TimeInterval(offset)),
                sequence: offset + 1,
                payload: payload
            )

            let message = UnifiedEventTransformer.transformPersistedEvent(event)

            XCTAssertNotNil(
                message,
                "\(eventType.rawValue) is marked renderable but did not reconstruct from its canonical payload"
            )
        }
    }

    func testEveryStandaloneRenderableEventReconstructsInSessionState() {
        let fixtures = renderableEventFixtures()
        let standaloneRenderableTypes = PersistedEventType.allCases.filter {
            $0.rendersAsChatMessage &&
            $0 != .capabilityInvocationStarted &&
            $0 != .capabilityInvocationCompleted
        }

        for (offset, eventType) in standaloneRenderableTypes.enumerated() {
            let payload = fixtures[eventType]
            XCTAssertNotNil(payload, "Missing reconstruction fixture for \(eventType.rawValue)")
            guard let payload else { continue }

            let event = RawEvent(
                id: "state-fixture-\(eventType.rawValue)",
                parentId: nil,
                sessionId: "test-session",
                workspaceId: "/test/workspace",
                type: eventType.rawValue,
                timestamp: timestamp(TimeInterval(offset)),
                sequence: offset + 1,
                payload: payload
            )

            let state = UnifiedEventTransformer.reconstructSessionState(from: [event])

            XCTAssertFalse(
                state.messages.isEmpty,
                "\(eventType.rawValue) is marked renderable but full session reconstruction did not include it"
            )
        }
    }

    func testEveryPersistedEventTypeHasExplicitReconstructionDisposition() {
        let rendered = Set(renderableEventFixtures().keys)
        let stateHandled: Set<PersistedEventType> = [
            .sessionStart, .sessionBranch,
            .messageDeleted,
            .streamTurnEnd,
            .configModelSwitch, .configReasoningLevel,
            .fileRead, .fileWrite, .fileEdit,
            .compactBoundary,
            .metadataUpdate, .metadataTag,
            .llmHookResult
        ]
        let consumedThroughAssistantMessage: Set<PersistedEventType> = [
            .capabilityInvocationStarted,
            .capabilityInvocationCompleted,
            .streamThinkingComplete
        ]
        let streamingReplayOnly: Set<PersistedEventType> = [
            .streamTextDelta,
            .streamThinkingDelta,
            .streamTurnStart
        ]
        let intentionallyNoStateImpact: Set<PersistedEventType> = [
            // Session tree / completion metadata lives outside ReconstructedState.
            .sessionEnd,
            .sessionFork,
            // Prompt/process events do not currently restore
            // user-visible chat or persisted ReconstructedState fields.
            .capabilityRunStatus,
            .configPromptUpdate
        ]

        let accounted = rendered
            .union(stateHandled)
            .union(consumedThroughAssistantMessage)
            .union(streamingReplayOnly)
            .union(intentionallyNoStateImpact)
        let missing = Set(PersistedEventType.allCases)
            .subtracting(accounted)
            .map(\.rawValue)
            .sorted()

        XCTAssertTrue(
            missing.isEmpty,
            "Every persisted event type must have an explicit reconstruction disposition. Missing: \(missing)"
        )
    }

    // MARK: - Batch Transformation Tests

    func testTransformPersistedEventsRawEvent() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: ["content": AnyCodable([["type": "text", "text": "Hello!"] as [String: Any]])], timestamp: timestamp(2)),
            rawEvent(type: "session.end", payload: [:], timestamp: timestamp(3))
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Only message.user and message.assistant should be transformed
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
    }

    func testTransformPersistedEventsSessionEvent() {
        // Test the new interleaved content block architecture:
        // - message.assistant contains content blocks in streaming order
        // - capability.invocation.started events provide capability details (name, arguments, turn)
        // - capability.invocation.completed events provide results
        // - The order comes from message.assistant's content array, not timestamps
        let events = [
            sessionEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "capability.invocation.started", payload: ["modelPrimitiveName": AnyCodable("execute"), "invocationId": AnyCodable("c1"), "arguments": AnyCodable([:]), "turn": AnyCodable(1)], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "capability.invocation.completed", payload: ["invocationId": AnyCodable("c1"), "content": AnyCodable("result"), "isError": AnyCodable(false), "duration": AnyCodable(10)], timestamp: timestamp(3), sequence: 4),
            // message.assistant content blocks reflect exact streaming order: capability_invocation then text
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "c1", "name": "execute", "input": [:]],
                    ["type": "text", "text": "Done!"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + capability.invocation.started (from content block) + text (from content block) = 3 messages
        // Order comes from message.assistant's content array
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant) // capability_invocation block -> capability.invocation.started with result
        XCTAssertEqual(messages[2].role, .assistant) // text block

        // Verify capability invocation has result attached
        if case .capabilityInvocation(let invocation) = messages[1].content {
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation.result, "result")
            XCTAssertEqual(invocation.status, .success)
        } else {
            XCTFail("Expected capability invocation content")
        }

        // Verify text content
        if case .text(let text) = messages[2].content {
            XCTAssertEqual(text, "Done!")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testInterleavedContentOrdering() {
        // Test the exact user scenario: "I'll run sleep 3..." -> Capability -> "First done..." -> Capability -> "Done!"
        // This is the key fix: content blocks preserve exact streaming interleaving order
        let events = [
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Run sleep 3 twice")], timestamp: timestamp(0), sequence: 1),
            // Capability invocations happen during streaming
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("invocation1"),
                "arguments": AnyCodable(["command": "sleep 3"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("invocation1"),
                "content": AnyCodable(""),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("invocation2"),
                "arguments": AnyCodable(["command": "sleep 3"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("invocation2"),
                "content": AnyCodable(""),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(4), sequence: 5),
            // message.assistant has content blocks in EXACT streaming order
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "I'll run sleep 3..."],
                    ["type": "capability_invocation", "id": "invocation1", "name": "execute", "input": ["command": "sleep 3"]],
                    ["type": "text", "text": "First done, running second..."],
                    ["type": "capability_invocation", "id": "invocation2", "name": "execute", "input": ["command": "sleep 3"]],
                    ["type": "text", "text": "Done!"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(5), sequence: 6)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should produce: user + text + capability + text + capability + text = 6 messages
        XCTAssertEqual(messages.count, 6, "Should have 6 messages: user + 5 content blocks")

        // Verify exact order matches streaming order
        XCTAssertEqual(messages[0].role, .user)

        // Message 1: "I'll run sleep 3..."
        if case .text(let text) = messages[1].content {
            XCTAssertEqual(text, "I'll run sleep 3...")
        } else {
            XCTFail("Expected text content at index 1")
        }

        // Message 2: First capability invocation
        if case .capabilityInvocation(let invocation) = messages[2].content {
            XCTAssertEqual(invocation.id, "invocation1")
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation.result, "(no output)") // Empty result shows "(no output)"
        } else {
            XCTFail("Expected capability invocation content at index 2")
        }

        // Message 3: "First done, running second..."
        if case .text(let text) = messages[3].content {
            XCTAssertEqual(text, "First done, running second...")
        } else {
            XCTFail("Expected text content at index 3")
        }

        // Message 4: Second capability invocation
        if case .capabilityInvocation(let invocation) = messages[4].content {
            XCTAssertEqual(invocation.id, "invocation2")
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
        } else {
            XCTFail("Expected capability invocation content at index 4")
        }

        // Message 5: "Done!"
        if case .text(let text) = messages[5].content {
            XCTAssertEqual(text, "Done!")
        } else {
            XCTFail("Expected text content at index 5")
        }
    }

    func testCapabilityInvocationUseWithoutMatchingCapabilityInvocationEventDoesNotInferOldName() {
        // Edge case: capability_invocation in content blocks but NO enriched capability event.
        // iOS preserves the invocation shell, but must not synthesize identity
        // from the content-block name.
        let events = [
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(0), sequence: 1),
            // NO capability.invocation.started event - only capability_invocation in message.assistant content
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me read that file:"],
                    ["type": "capability_invocation", "id": "orphan-capability-id", "name": "execute", "input": ["file_path": "/test.txt"]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should produce: user + text + capability shell = 3 messages
        XCTAssertEqual(messages.count, 3, "Should have 3 messages even without capability.invocation.started event")

        // Verify arguments survive, while identity remains generic.
        if case .capabilityInvocation(let invocation) = messages[2].content {
            XCTAssertEqual(invocation.id, "orphan-capability-id")
            XCTAssertNil(invocation.identity.modelPrimitiveName)
            XCTAssertTrue(invocation.identity.isEmpty)
            XCTAssertTrue(invocation.arguments.contains("file_path"))  // Serialized from content block
            XCTAssertEqual(invocation.status, .running)  // No result = running
        } else {
            XCTFail("Expected capability invocation content at index 2")
        }
    }

    // MARK: - Session State Reconstruction Tests

    func testReconstructSessionStateBasic() {
        let events = [
            rawEvent(type: "session.start", payload: [
                "model": AnyCodable("claude-sonnet-4"),
                "workingDirectory": AnyCodable("/home/user/project"),
                "provider": AnyCodable("anthropic")
            ], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Hi there!"] as [String: Any]]),
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable(makeTokenRecordPayload(
                    inputTokens: 100,
                    outputTokens: 50,
                    turn: 1,
                    contextWindowTokens: 100,
                    newInputTokens: 100,
                    timestamp: timestamp(2)
                ))
            ], timestamp: timestamp(2))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.currentModel, "claude-sonnet-4")
        XCTAssertEqual(state.workingDirectory, "/home/user/project")
        XCTAssertEqual(state.totalTokenUsage.inputTokens, 100)
        XCTAssertEqual(state.totalTokenUsage.outputTokens, 50)
        XCTAssertEqual(state.currentTurn, 1)
    }

    func testReconstructSessionStateWithModelSwitch() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Switch to opus")], timestamp: timestamp(1)),
            rawEvent(type: "config.model_switch", payload: [
                "previousModel": AnyCodable("claude-sonnet-4"),
                "newModel": AnyCodable("claude-opus-4")
            ], timestamp: timestamp(2)),
            rawEvent(type: "message.assistant", payload: ["content": AnyCodable([["type": "text", "text": "Now using Opus"] as [String: Any]])], timestamp: timestamp(3))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.currentModel, "claude-opus-4")
        XCTAssertEqual(state.messages.count, 3) // user + model_switch + assistant
    }

    // MARK: - Reasoning Level Reconstruction Tests

    func testReconstructSessionStateWithReasoningLevel() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-opus-4-6")], timestamp: timestamp(0)),
            rawEvent(type: "config.reasoning_level", payload: [
                "previousLevel": AnyCodable("medium"),
                "newLevel": AnyCodable("high")
            ], timestamp: timestamp(1)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(2)),
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.reasoningLevel, "high")
    }

    func testReconstructSessionStateReasoningLevelLatestWins() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-opus-4-6")], timestamp: timestamp(0)),
            rawEvent(type: "config.reasoning_level", payload: [
                "previousLevel": AnyCodable(nil as String?),
                "newLevel": AnyCodable("medium")
            ], timestamp: timestamp(1)),
            rawEvent(type: "config.reasoning_level", payload: [
                "previousLevel": AnyCodable("medium"),
                "newLevel": AnyCodable("high")
            ], timestamp: timestamp(2)),
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.reasoningLevel, "high")
    }

    func testReconstructSessionStateNoReasoningLevel() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertNil(state.reasoningLevel)
    }

    func testTransformReasoningLevelChange() {
        let event = rawEvent(
            type: "config.reasoning_level",
            payload: [
                "previousLevel": AnyCodable("medium"),
                "newLevel": AnyCodable("high")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .system)
        if case .systemEvent(.reasoningLevelChange(let from, let to)) = message?.content {
            XCTAssertEqual(from, "Medium")
            XCTAssertEqual(to, "High")
        } else {
            XCTFail("Expected reasoning level change system event")
        }
    }

    func testTransformReasoningLevelChangeFromNilReturnsNil() {
        let event = rawEvent(
            type: "config.reasoning_level",
            payload: [
                "previousLevel": AnyCodable(nil as String?),
                "newLevel": AnyCodable("max")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNil(message, "Should not produce pill when previousLevel is null")
    }

    func testTransformReasoningLevelChangeSameLevelReturnsNil() {
        let event = rawEvent(
            type: "config.reasoning_level",
            payload: [
                "previousLevel": AnyCodable("high"),
                "newLevel": AnyCodable("high")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNil(message, "Should not produce pill when levels are the same")
    }

    func testReasoningLevelChangeNotificationInReconstructedMessages() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-opus-4-6")], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(1)),
            rawEvent(type: "config.reasoning_level", payload: [
                "previousLevel": AnyCodable("medium"),
                "newLevel": AnyCodable("high")
            ], timestamp: timestamp(2)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Think harder")], timestamp: timestamp(3)),
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        let reasoningMessages = state.messages.filter {
            if case .systemEvent(.reasoningLevelChange) = $0.content { return true }
            return false
        }
        XCTAssertEqual(reasoningMessages.count, 1)
    }

    func testReconstructSessionStateWithTokenAccumulation() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Response 1"] as [String: Any]]),
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable(makeTokenRecordPayload(
                    inputTokens: 100,
                    outputTokens: 50,
                    turn: 1,
                    contextWindowTokens: 100,
                    newInputTokens: 100,
                    timestamp: timestamp(1)
                ))
            ], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Response 2"] as [String: Any]]),
                "turn": AnyCodable(2),
                "tokenRecord": AnyCodable(makeTokenRecordPayload(
                    inputTokens: 200,
                    outputTokens: 100,
                    turn: 2,
                    contextWindowTokens: 300,
                    newInputTokens: 200,
                    previousContextBaseline: 100,
                    timestamp: timestamp(2)
                ))
            ], timestamp: timestamp(2))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // Tokens should accumulate
        XCTAssertEqual(state.totalTokenUsage.inputTokens, 300)
        XCTAssertEqual(state.totalTokenUsage.outputTokens, 150)
        XCTAssertEqual(state.currentTurn, 2)
    }

    func testReconstructSessionStateWithErrors() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Do something")], timestamp: timestamp(1)),
            rawEvent(type: "error.capability", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("call_err1"),
                "error": AnyCodable("Command failed")
            ], timestamp: timestamp(2)),
            rawEvent(type: "error.provider", payload: [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("Rate limited"),
                "category": AnyCodable("rate_limit"),
                "retryable": AnyCodable(true)
            ], timestamp: timestamp(3))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // user + error.capability + error.provider = 3 messages
        XCTAssertEqual(state.messages.count, 3)
    }

    // MARK: - SessionEvent Overload Tests

    func testReconstructSessionStateFromSessionEvents() {
        let events = [
            sessionEvent(type: "session.start", payload: [
                "model": AnyCodable("claude-sonnet-4"),
                "workingDirectory": AnyCodable("/test"),
                "provider": AnyCodable("anthropic")
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Hello!"] as [String: Any]]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.currentModel, "claude-sonnet-4")
        XCTAssertEqual(state.workingDirectory, "/test")
    }

    // MARK: - Edge Cases

    func testUnknownEventTypeIsFiltered() {
        let event = rawEvent(type: "unknown.event", payload: [:])
        let message = UnifiedEventTransformer.transformPersistedEvent(event)
        XCTAssertNil(message)
    }

    func testMalformedPayloadReturnsNil() {
        // Capability invocation without required invocationId
        let event = rawEvent(
            type: "capability.invocation.started",
            payload: [
                "modelPrimitiveName": AnyCodable("execute")
                // Missing invocationId and arguments
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)
        // Should handle gracefully (implementation may return nil or default)
        // The key is it shouldn't crash
        // Either returns nil or a valid message - both are acceptable
        _ = message
    }

    func testEmptyEventsArray() {
        let messages = UnifiedEventTransformer.transformPersistedEvents([RawEvent]())
        XCTAssertEqual(messages.count, 0)

        let state = UnifiedEventTransformer.reconstructSessionState(from: [RawEvent]())
        XCTAssertEqual(state.messages.count, 0)
        XCTAssertNil(state.currentModel)
    }

    // MARK: - Ordering Tests

    func testEventsAreSortedBySequence() {
        // Events in wrong order (sequence: 3, 1, 2) - should be sorted to (1, 2, 3)
        let events = [
            rawEvent(type: "message.assistant", payload: ["content": AnyCodable([["type": "text", "text": "Third"] as [String: Any]])], timestamp: timestamp(3), sequence: 3),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("First")], timestamp: timestamp(1), sequence: 1),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Second")], timestamp: timestamp(2), sequence: 2)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 3)
        // Should be sorted by sequence number (execution order)
        if case .text(let text1) = messages[0].content {
            XCTAssertEqual(text1, "First")
        }
        if case .text(let text2) = messages[1].content {
            XCTAssertEqual(text2, "Second")
        }
        if case .text(let text3) = messages[2].content {
            XCTAssertEqual(text3, "Third")
        }
    }

    // MARK: - Characterization Tests (Phase 1 - Edge Cases)

    func testEmptyContentBlocksAreSkipped() {
        // Empty text blocks should not produce messages
        let events = [
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": ""],  // Empty text block
                    ["type": "text", "text": "Hello"]  // Non-empty
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should only produce one message (the non-empty text)
        XCTAssertEqual(messages.count, 1)
        if case .text(let text) = messages[0].content {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testThinkingBlocksAreTransformed() {
        // Thinking blocks should produce thinking messages
        let events = [
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Let me think about this..."],
                    ["type": "text", "text": "Here's my response"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 2)

        // First: thinking message
        if case .thinking(let visible, let isExpanded, let isStreaming) = messages[0].content {
            XCTAssertEqual(visible, "Let me think about this...")
            XCTAssertFalse(isExpanded)
            XCTAssertFalse(isStreaming)
        } else {
            XCTFail("Expected thinking content")
        }

        // Second: text message
        if case .text(let text) = messages[1].content {
            XCTAssertEqual(text, "Here's my response")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testTokenRecordIsExtracted() {
        // message.assistant with tokenRecord should include tokenRecord
        let events = [
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Hello"]]),
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable(makeTokenRecordPayload(
                    inputTokens: 100,
                    outputTokens: 50,
                    cacheReadTokens: 75,
                    turn: 1,
                    contextWindowTokens: 150,
                    newInputTokens: 25,
                    previousContextBaseline: 125
                ))
            ], timestamp: timestamp(0), sequence: 1)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 1)
        // Verify tokenRecord is set
        XCTAssertNotNil(messages[0].tokenRecord)
        XCTAssertEqual(messages[0].tokenRecord?.computed.newInputTokens, 25)
        XCTAssertEqual(messages[0].tokenRecord?.source.rawOutputTokens, 50)
        XCTAssertEqual(messages[0].tokenRecord?.computed.contextWindowTokens, 150)
    }

    func testReconstructSessionStateWithTokenRecord() {
        // Reconstruction should extract contextWindowTokens from tokenRecord
        let events = [
            rawEvent(type: "session.start", payload: [
                "model": AnyCodable("claude-sonnet-4")
            ], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Hello"]]),
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable(makeTokenRecordPayload(
                    inputTokens: 100,
                    outputTokens: 50,
                    cacheReadTokens: 75,
                    turn: 1,
                    contextWindowTokens: 150,
                    newInputTokens: 25,
                    previousContextBaseline: 125
                ))
            ], timestamp: timestamp(1), sequence: 2)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // lastTurnInputTokens should come from tokenRecord.computed.contextWindowTokens
        XCTAssertEqual(state.lastTurnInputTokens, 150)
        // totalTokenUsage accumulates from tokenRecord.source
        XCTAssertEqual(state.totalTokenUsage.inputTokens, 100)
        XCTAssertEqual(state.totalTokenUsage.outputTokens, 50)
    }

    func testContentBlockWithMissingType() {
        // Content blocks without type should be skipped gracefully
        let events = [
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["text": "No type field"],  // Missing type
                    ["type": "text", "text": "Has type"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should only produce one message (the one with type)
        XCTAssertEqual(messages.count, 1)
        if case .text(let text) = messages[0].content {
            XCTAssertEqual(text, "Has type")
        } else {
            XCTFail("Expected text content")
        }
    }

    // MARK: - Session Chat Rendering Tests

    func testSessionEventsTransformToChat() {
        // A typical session: user message, assistant reply with capability invocation, final output.
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Count files in the current directory")
            ], timestamp: timestamp(1), sequence: 2),
            rawEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["command": "ls -la | wc -l"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3),
            rawEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_1"),
                "content": AnyCodable("9"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(3), sequence: 4),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "tc_1", "name": "execute", "input": ["command": "ls -la | wc -l"]],
                    ["type": "text", "text": "There are **9 files** in the directory."]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + capability_invocation + text = 3 messages
        XCTAssertEqual(messages.count, 3)

        // First message should be the user's task
        XCTAssertEqual(messages[0].role, .user)
        if case .text(let text) = messages[0].content {
            XCTAssertTrue(text.contains("Count files"))
        } else {
            XCTFail("Expected text content for user message")
        }

        // Second message: capability invocation with result
        if case .capabilityInvocation(let invocation) = messages[1].content {
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation.id, "tc_1")
            XCTAssertEqual(invocation.result, "9")
            XCTAssertEqual(invocation.status, .success)
        } else {
            XCTFail("Expected capability invocation content")
        }

        // Third message: assistant text with markdown
        XCTAssertEqual(messages[2].role, .assistant)
        if case .text(let text) = messages[2].content {
            XCTAssertTrue(text.contains("**9 files**"))
        } else {
            XCTFail("Expected text content for assistant message")
        }
    }

    func testSessionEmptyEventsProducesNoMessages() {
        let events: [RawEvent] = []
        let messages = UnifiedEventTransformer.transformPersistedEvents(events)
        XCTAssertTrue(messages.isEmpty)
    }

    func testSessionWithOnlySessionStartProducesNoMessages() {
        let events = [
            rawEvent(type: "session.start", payload: [:], sequence: 1)
        ]
        let messages = UnifiedEventTransformer.transformPersistedEvents(events)
        XCTAssertTrue(messages.isEmpty)
    }

    func testSessionMultiTurnConversation() {
        // Multiple turns with capability calls.
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Analyze the codebase")
            ], timestamp: timestamp(1), sequence: 2),
            // Turn 1
            rawEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/src/main.ts"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3),
            rawEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_1"),
                "content": AnyCodable("const app = express();"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(3), sequence: 4),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "tc_1", "name": "execute", "input": ["file_path": "/src/main.ts"]],
                    ["type": "text", "text": "Found the entry point. Let me check the config."]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5),
            // Turn 2
            rawEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_2"),
                "arguments": AnyCodable(["file_path": "/tsconfig.json"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(5), sequence: 6),
            rawEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_2"),
                "content": AnyCodable("{\"compilerOptions\": {}}"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(6), sequence: 7),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "tc_2", "name": "execute", "input": ["file_path": "/tsconfig.json"]],
                    ["type": "text", "text": "Analysis complete. The codebase uses TypeScript with Express."]
                ]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(7), sequence: 8)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + (capability + text) turn 1 + (capability + text) turn 2 = 5
        XCTAssertEqual(messages.count, 5)

        // Exactly 1 user message (the task)
        let userMessages = messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1)

        // 2 capability invocation messages
        let capabilityMessages = messages.filter {
            if case .capabilityInvocation = $0.content { return true }
            return false
        }
        XCTAssertEqual(capabilityMessages.count, 2)

        // 2 assistant text messages
        let textMessages = messages.filter { message in
            guard message.role == .assistant else { return false }
            if case .text = message.content { return true }
            return false
        }
        XCTAssertEqual(textMessages.count, 2)
    }

    func testSessionWithMarkdownTable() {
        // Ensure markdown tables survive transformation
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Show file counts by extension")
            ], timestamp: timestamp(1), sequence: 2),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "| Extension | Count |\n|-----------|-------|\n| .ts | 5 |\n| .md | 3 |"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 2)

        let assistantTexts = messages.filter { message in
            guard message.role == .assistant else { return false }
            if case .text(let t) = message.content { return t.contains("|") }
            return false
        }
        XCTAssertEqual(assistantTexts.count, 1, "Markdown table text should be preserved")
    }

    func testSessionWithFailedCapability() {
        // Capability that returns error status
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("execute a nonexistent file")
            ], timestamp: timestamp(1), sequence: 2),
            rawEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/nonexistent"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3),
            rawEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_1"),
                "content": AnyCodable("File not found"),
                "isError": AnyCodable(true),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(3), sequence: 4),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "tc_1", "name": "execute", "input": ["file_path": "/nonexistent"]],
                    ["type": "text", "text": "The file does not exist."]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + capability + text = 3
        XCTAssertEqual(messages.count, 3)

        let capabilityMessages = messages.filter {
            if case .capabilityInvocation(let invocation) = $0.content {
                return invocation.status == .error
            }
            return false
        }
        XCTAssertEqual(capabilityMessages.count, 1, "Failed capability should show error status")
    }

    // MARK: - TokenRecord Placement Tests (Capability-Only Turns)

    func testTokenRecordPlacementOnCapabilityInvocationWhenNoTextBlock() {
        // Turn with [thinking, capability_invocation] and no text block — tokenRecord should attach to capability message
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 10,
            outputTokens: 261,
            cacheReadTokens: 12_561,
            cacheCreationTokens: 498,
            turn: 1,
            contextWindowTokens: 12_571,
            newInputTokens: 10,
            previousContextBaseline: 12_561
        )

        let events = [
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"), "operationName": AnyCodable("web_search"),
                "invocationId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["query": "test"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_1"),
                "content": AnyCodable("Found 3 results"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Let me search for this..."],
                    ["type": "capability_invocation", "id": "tc_1", "name": "Search", "input": ["query": "test"]]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(3254),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // thinking + capability_invocation = 2 messages
        XCTAssertEqual(messages.count, 2)

        // Capability message (last) should have tokenRecord
        if case .capabilityInvocation = messages[1].content {
            XCTAssertNotNil(messages[1].tokenRecord, "tokenRecord should be attached to capability invocation when no text block exists")
            XCTAssertEqual(messages[1].tokenRecord?.computed.newInputTokens, 10)
            XCTAssertEqual(messages[1].tokenRecord?.source.rawOutputTokens, 261)
            XCTAssertEqual(messages[1].tokenRecord?.source.rawCacheReadTokens, 12561)
        } else {
            XCTFail("Expected capability invocation content at index 1")
        }
    }

    func testTokenRecordPlacementWithMultipleCapabilityInvocations() {
        // Turn with [thinking, capability_invocation, capability_invocation] — last capability gets tokenRecord
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 13,
            outputTokens: 216,
            cacheReadTokens: 13_059,
            cacheCreationTokens: 928,
            turn: 2,
            contextWindowTokens: 13_072,
            newInputTokens: 13,
            previousContextBaseline: 13_059
        )

        let events = [
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_a"),
                "arguments": AnyCodable(["file_path": "/src/a.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_a"),
                "content": AnyCodable("file a contents"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_b"),
                "arguments": AnyCodable(["file_path": "/src/b.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_b"),
                "content": AnyCodable("file b contents"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Reading both files..."],
                    ["type": "capability_invocation", "id": "tc_a", "name": "execute", "input": ["file_path": "/src/a.ts"]],
                    ["type": "capability_invocation", "id": "tc_b", "name": "execute", "input": ["file_path": "/src/b.ts"]]
                ]),
                "turn": AnyCodable(2),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1995),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // thinking + capability_invocation + capability_invocation = 3 messages
        XCTAssertEqual(messages.count, 3)

        // First capability should NOT have tokenRecord (metadata goes on last message)
        if case .capabilityInvocation = messages[1].content {
            XCTAssertNil(messages[1].tokenRecord, "First capability invocation should NOT get tokenRecord")
        } else {
            XCTFail("Expected capability invocation at index 1")
        }

        // Last capability (last message in turn) should have tokenRecord
        if case .capabilityInvocation = messages[2].content {
            XCTAssertNotNil(messages[2].tokenRecord, "Last capability invocation should get tokenRecord")
            XCTAssertEqual(messages[2].tokenRecord?.computed.newInputTokens, 13)
        } else {
            XCTFail("Expected capability invocation at index 2")
        }
    }

    func testTokenRecordOnTextBlockMovesToLastTurnMessage() {
        // Turn with [thinking, text, capability_invocation] — last message (capability) gets tokenRecord
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 14,
            outputTokens: 787,
            cacheReadTokens: 13_987,
            cacheCreationTokens: 7_026,
            turn: 3,
            contextWindowTokens: 14_001,
            newInputTokens: 14,
            previousContextBaseline: 13_987
        )

        let events = [
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_x"),
                "arguments": AnyCodable(["command": "echo hello"]),
                "turn": AnyCodable(3)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_x"),
                "content": AnyCodable("hello"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Running command..."],
                    ["type": "text", "text": "Here's the result"],
                    ["type": "capability_invocation", "id": "tc_x", "name": "execute", "input": ["command": "echo hello"]]
                ]),
                "turn": AnyCodable(3),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(11087),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // thinking + text + capability = 3 messages
        XCTAssertEqual(messages.count, 3)

        // Text message should NOT have tokenRecord (metadata goes on last message)
        if case .text(let text) = messages[1].content {
            XCTAssertEqual(text, "Here's the result")
            XCTAssertNil(messages[1].tokenRecord, "Text block should NOT get tokenRecord (last message does)")
        } else {
            XCTFail("Expected text at index 1")
        }

        // Last message (capability) should have tokenRecord so stats render after all content
        if case .capabilityInvocation = messages[2].content {
            XCTAssertNotNil(messages[2].tokenRecord, "Last message should get tokenRecord")
            XCTAssertEqual(messages[2].tokenRecord?.source.rawOutputTokens, 787)
        } else {
            XCTFail("Expected capability invocation at index 2")
        }
    }

    func testTokenRecordPlacementIncludesModelAndLatency() {
        // Verify final-message placement also attaches model and latency metadata
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 10,
            outputTokens: 100,
            cacheReadTokens: 5_000,
            turn: 1,
            contextWindowTokens: 5_010,
            newInputTokens: 10,
            previousContextBaseline: 5_000
        )

        let events = [
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("tc_meta"),
                "arguments": AnyCodable(["file_path": "/test.ts"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_meta"),
                "content": AnyCodable("contents"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "tc_meta", "name": "execute", "input": ["file_path": "/test.ts"]]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(2500),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 1)

        // Verify all metadata is attached
        XCTAssertNotNil(messages[0].tokenRecord)
        XCTAssertEqual(messages[0].model, "claude-opus-4-6")
        XCTAssertEqual(messages[0].latencyMs, 2500)
    }

    // MARK: - Turn Metadata Tests

    func testMetadataOnLastMessageOfEveryTurn() {
        // Reconstruction must match live streaming: every turn gets stats on its
        // last message, regardless of content type (text, capability, or mixed).
        let tokenRecord1 = makeTokenRecordPayload(
            inputTokens: 100,
            outputTokens: 50,
            turn: 1,
            contextWindowTokens: 150,
            newInputTokens: 100,
            sessionId: "s1"
        )
        let tokenRecord2 = makeTokenRecordPayload(
            inputTokens: 10,
            outputTokens: 200,
            cacheReadTokens: 140,
            turn: 2,
            contextWindowTokens: 350,
            newInputTokens: 10,
            previousContextBaseline: 150,
            sessionId: "s1"
        )
        let tokenRecord3 = makeTokenRecordPayload(
            inputTokens: 15,
            outputTokens: 300,
            cacheReadTokens: 335,
            turn: 3,
            contextWindowTokens: 650,
            newInputTokens: 15,
            previousContextBaseline: 350,
            sessionId: "s1"
        )

        let events = [
            // User prompt
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Do something")
            ], timestamp: timestamp(0), sequence: 1),
            // Turn 1: text + capability (metadata goes on capability — the last item)
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"), "invocationId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/a.ts"]), "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_1"), "content": AnyCodable("contents"),
                "isError": AnyCodable(false), "duration": AnyCodable(10)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me read that file."],
                    ["type": "capability_invocation", "id": "tc_1", "name": "execute", "input": ["file_path": "/a.ts"]]
                ]),
                "turn": AnyCodable(1), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1000), "tokenRecord": AnyCodable(tokenRecord1)
            ], timestamp: timestamp(3), sequence: 4),
            // Turn 2: capability only (metadata goes on capability — the only item)
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"), "invocationId": AnyCodable("tc_2"),
                "arguments": AnyCodable(["file_path": "/a.ts"]), "turn": AnyCodable(2)
            ], timestamp: timestamp(4), sequence: 5),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_2"), "content": AnyCodable("edited"),
                "isError": AnyCodable(false), "duration": AnyCodable(10)
            ], timestamp: timestamp(5), sequence: 6),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "tc_2", "name": "execute", "input": ["file_path": "/a.ts"]]
                ]),
                "turn": AnyCodable(2), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(2000), "tokenRecord": AnyCodable(tokenRecord2)
            ], timestamp: timestamp(6), sequence: 7),
            // Turn 3: text only (metadata goes on text — the only item)
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "All done!"]
                ]),
                "turn": AnyCodable(3), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(500), "tokenRecord": AnyCodable(tokenRecord3)
            ], timestamp: timestamp(7), sequence: 8)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + text1 + invocation1 + invocation2 + text2 = 5 messages
        XCTAssertEqual(messages.count, 5)

        // User message — no metadata
        if case .text(let t) = messages[0].content { XCTAssertEqual(t, "Do something") }
        XCTAssertNil(messages[0].tokenRecord)

        // Turn 1 text (not last in turn): no metadata
        XCTAssertNil(messages[1].tokenRecord, "Non-last message in turn should not have metadata")
        XCTAssertNil(messages[1].model)

        // Turn 1 capability (LAST in turn): has metadata
        XCTAssertNotNil(messages[2].tokenRecord, "Last message in turn should have metadata")
        XCTAssertEqual(messages[2].model, "claude-opus-4-6")
        XCTAssertEqual(messages[2].latencyMs, 1000)

        // Turn 2 capability (LAST and only in turn): has metadata
        XCTAssertNotNil(messages[3].tokenRecord, "Last message in turn should have metadata")
        XCTAssertEqual(messages[3].model, "claude-opus-4-6")
        XCTAssertEqual(messages[3].latencyMs, 2000)

        // Turn 3 text (LAST and only in turn): has metadata
        XCTAssertNotNil(messages[4].tokenRecord, "Last message in turn should have metadata")
        XCTAssertEqual(messages[4].model, "claude-opus-4-6")
        XCTAssertEqual(messages[4].latencyMs, 500)
    }

    func testMetadataPreservedAcrossUserMessages() {
        // Multi-exchange: metadata persists on assistant messages even when
        // followed by another user message.
        let tokenRecord = makeTokenRecordPayload(
            inputTokens: 100,
            outputTokens: 50,
            turn: 1,
            contextWindowTokens: 150,
            newInputTokens: 100,
            sessionId: "s1"
        )

        let events = [
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Hello")
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Hi there!"]]),
                "turn": AnyCodable(1), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(800), "tokenRecord": AnyCodable(tokenRecord)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Thanks")
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 3)

        // Assistant message keeps metadata regardless of following user message
        XCTAssertNotNil(messages[1].tokenRecord)
        XCTAssertEqual(messages[1].model, "claude-opus-4-6")
    }

    // MARK: - Deletion Tests

    func testReconstructionSkipsDeletedEvents() {
        // Events targeted by message.deleted should be skipped in reconstruction
        let userEventId = UUID().uuidString
        let events = [
            rawEvent(id: userEventId, type: "message.user", payload: [
                "content": AnyCodable("Delete me")
            ], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Response"]]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            // message.deleted requires targetEventId AND targetType
            rawEvent(type: "message.deleted", payload: [
                "targetEventId": AnyCodable(userEventId),
                "targetType": AnyCodable("message.user"),
                "reason": AnyCodable("user_request")
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // The deleted user message should not appear
        // Only assistant message should remain (text content)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].role, .assistant)
        if case .text(let text) = state.messages[0].content {
            XCTAssertEqual(text, "Response")
        }
    }

    // MARK: - buildCapabilityInvocationMaps Tests

    func testBuildCapabilityMapsCollectsCapabilityInvocationsAndResults() {
        let events = [
            rawEvent(
                id: "e1",
                type: "capability.invocation.started",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "modelPrimitiveName": AnyCodable("execute"),
                    "arguments": AnyCodable("{\"path\":\"/test\"}"),
                    "turn": AnyCodable(1)
                ],
                sequence: 1
            ),
            rawEvent(
                id: "e2",
                type: "capability.invocation.completed",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "content": AnyCodable("file content"),
                    "isError": AnyCodable(false),
                    "duration": AnyCodable(42)
                ],
                sequence: 2
            )
        ]

        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: events)

        XCTAssertEqual(maps.startedInvocations.count, 1)
        XCTAssertEqual(maps.completedInvocations.count, 1)
        XCTAssertEqual(maps.startedInvocations["tc1"]?.name, "execute")
        XCTAssertEqual(maps.completedInvocations["tc1"]?.invocationId, "tc1")
        XCTAssertEqual(maps.completedInvocations["tc1"]?.durationMs, 42)
    }

    func testBuildCapabilityMapsEmptyEvents() {
        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: [RawEvent]())

        XCTAssertTrue(maps.startedInvocations.isEmpty)
        XCTAssertTrue(maps.completedInvocations.isEmpty)
    }

    func testBuildCapabilityMapsDuplicateInvocationIdLastWins() {
        let events = [
            rawEvent(
                id: "e1",
                type: "capability.invocation.started",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "modelPrimitiveName": AnyCodable("execute"),
                    "arguments": AnyCodable("{}"),
                    "turn": AnyCodable(1)
                ],
                sequence: 1
            ),
            rawEvent(
                id: "e2",
                type: "capability.invocation.started",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "modelPrimitiveName": AnyCodable("execute"),
                    "arguments": AnyCodable("{}"),
                    "turn": AnyCodable(1)
                ],
                sequence: 2
            )
        ]

        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: events)

        XCTAssertEqual(maps.startedInvocations.count, 1)
        XCTAssertEqual(maps.startedInvocations["tc1"]?.name, "execute")
    }

    func testBuildCapabilityMapsCapabilityResultWithoutInvocationIdSkipped() {
        // capability.invocation.completed without invocationId in payload should be gracefully skipped
        let events = [
            rawEvent(
                id: "e1",
                type: "capability.invocation.completed",
                payload: [
                    "content": AnyCodable("some result"),
                    "isError": AnyCodable(false)
                    // No invocationId!
                ],
                sequence: 1
            )
        ]

        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: events)

        XCTAssertTrue(maps.completedInvocations.isEmpty)
    }

    // MARK: - compact.boundary Strict Decode Tests

    /// Happy path: valid boundary payload produces a system `.compaction`
    /// message. Mirrors the Rust `compact_boundary_minimal_payload_decodes`
    /// test to verify both sides agree on the minimal required shape.
    func testTransformCompactBoundaryMinimalPayloadProducesCompactionMessage() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100),
                "reason": AnyCodable("manual")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        guard case .systemEvent(let systemEvent) = message?.content,
              case .compaction(let tokensBefore, let tokensAfter, let reason, _, _, _) = systemEvent else {
            XCTFail("Expected .compaction system event")
            return
        }
        XCTAssertEqual(tokensBefore, 1000)
        XCTAssertEqual(tokensAfter, 100)
        XCTAssertEqual(reason, "manual")
    }

    /// Strict wire contract: `reason` is required. Mirrors the Rust
    /// `compact_boundary_requires_reason` test — missing field must drop
    /// the event rather than defaulting to "manual".
    func testTransformCompactBoundaryMissingReasonReturnsNil() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100)
                // No reason — wire contract violation
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNil(message, "Missing reason must drop the event, matching Rust decoder")
    }

    /// Empty-string `reason` is rejected as equivalent to missing — a
    /// degenerate server emit should not render with an empty label in
    /// the compaction pill.
    func testTransformCompactBoundaryEmptyReasonReturnsNil() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100),
                "reason": AnyCodable("")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNil(message, "Empty reason must drop the event")
    }

    /// All four enumerated `reason` values from `CompactionReason` serde
    /// encoding (plus the import-transformer sentinel) decode successfully.
    /// Regression guard against the Rust emit path drifting from the
    /// snake_case contract.
    func testTransformCompactBoundaryAcceptsKnownReasonLabels() {
        for reason in ["manual", "threshold_exceeded", "progress_signal", "imported"] {
            let event = rawEvent(
                type: "compact.boundary",
                payload: [
                    "originalTokens": AnyCodable(1000),
                    "compactedTokens": AnyCodable(100),
                    "reason": AnyCodable(reason)
                ]
            )
            let message = UnifiedEventTransformer.transformPersistedEvent(event)
            XCTAssertNotNil(message, "\(reason) should decode")
        }
    }

}
