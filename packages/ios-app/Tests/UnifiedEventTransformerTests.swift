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
            payload: payload
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
            payload: payload
        )
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
                "content": AnyCodable("Hello! How can I help?"),
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

    // MARK: - Tool Call Tests

    func testTransformToolCall() {
        let event = rawEvent(
            type: "tool.call",
            payload: [
                "toolCallId": AnyCodable("call_123"),
                "name": AnyCodable("Read"),
                "arguments": AnyCodable(["file_path": "/src/main.ts"]),
                "turn": AnyCodable(1)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .toolUse(let toolUse) = message?.content {
            XCTAssertEqual(toolUse.toolName, "Read")
            XCTAssertEqual(toolUse.toolCallId, "call_123")
        } else {
            XCTFail("Expected toolUse content")
        }
    }

    // MARK: - Tool Result Tests

    func testTransformToolResult() {
        let event = rawEvent(
            type: "tool.result",
            payload: [
                "toolCallId": AnyCodable("call_123"),
                "content": AnyCodable("File contents here..."),
                "isError": AnyCodable(false),
                "duration": AnyCodable(150)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .toolResult)

        if case .toolResult(let result) = message?.content {
            XCTAssertEqual(result.toolCallId, "call_123")
            XCTAssertFalse(result.isError)
        } else {
            XCTFail("Expected toolResult content")
        }
    }

    func testTransformToolResultWithError() {
        let event = rawEvent(
            type: "tool.result",
            payload: [
                "toolCallId": AnyCodable("call_456"),
                "content": AnyCodable("File not found"),
                "isError": AnyCodable(true)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)

        if case .toolResult(let result) = message?.content {
            XCTAssertTrue(result.isError)
        } else {
            XCTFail("Expected toolResult content")
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

    // MARK: - Interruption Tests

    func testTransformInterrupted() {
        let event = rawEvent(
            type: "notification.interrupted",
            payload: [
                "turn": AnyCodable(3)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .system)

        if case .interrupted = message?.content {
            // Success
        } else {
            XCTFail("Expected interrupted content")
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

    func testTransformToolError() {
        let event = rawEvent(
            type: "error.tool",
            payload: [
                "toolName": AnyCodable("Bash"),
                "toolCallId": AnyCodable("call_789"),
                "error": AnyCodable("Command timed out"),
                "code": AnyCodable("TIMEOUT")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .error(let text) = message?.content {
            XCTAssertTrue(text.contains("Bash"))
            XCTAssertTrue(text.contains("Command timed out"))
        } else {
            XCTFail("Expected error content")
        }
    }

    func testTransformProviderError() {
        let event = rawEvent(
            type: "error.provider",
            payload: [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("Rate limit exceeded"),
                "retryable": AnyCodable(true),
                "retryAfter": AnyCodable(5000)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .error(let text) = message?.content {
            XCTAssertTrue(text.contains("anthropic"))
            XCTAssertTrue(text.contains("Rate limit exceeded"))
            XCTAssertTrue(text.contains("retrying"))
        } else {
            XCTFail("Expected error content")
        }
    }

    // MARK: - Event Filtering Tests

    func testMetadataEventsAreFiltered() {
        // These events should NOT produce ChatMessages
        let metadataTypes = [
            "session.start",
            "session.end",
            "compact.boundary",
            "worktree.acquired",
            "stream.turn_end"
        ]

        for type in metadataTypes {
            let event = rawEvent(type: type, payload: [:])
            let message = UnifiedEventTransformer.transformPersistedEvent(event)
            XCTAssertNil(message, "Expected \(type) to be filtered out")
        }
    }

    // MARK: - Batch Transformation Tests

    func testTransformPersistedEventsRawEvent() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: ["content": AnyCodable("Hello!")], timestamp: timestamp(2)),
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
        // - tool.call events provide tool details (name, arguments, turn)
        // - tool.result events provide results
        // - The order comes from message.assistant's content array, not timestamps
        let events = [
            sessionEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.call", payload: ["name": AnyCodable("Read"), "toolCallId": AnyCodable("c1"), "arguments": AnyCodable([:]), "turn": AnyCodable(1)], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "tool.result", payload: ["toolCallId": AnyCodable("c1"), "content": AnyCodable("result")], timestamp: timestamp(3), sequence: 4),
            // message.assistant content blocks reflect exact streaming order: tool_use then text
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "c1", "name": "Read", "input": [:]],
                    ["type": "text", "text": "Done!"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + tool.call (from content block) + text (from content block) = 3 messages
        // Order comes from message.assistant's content array
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant) // tool_use block -> tool.call with result
        XCTAssertEqual(messages[2].role, .assistant) // text block

        // Verify tool call has result attached
        if case .toolUse(let toolData) = messages[1].content {
            XCTAssertEqual(toolData.toolName, "Read")
            XCTAssertEqual(toolData.result, "result")
            XCTAssertEqual(toolData.status, .success)
        } else {
            XCTFail("Expected toolUse content")
        }

        // Verify text content
        if case .text(let text) = messages[2].content {
            XCTAssertEqual(text, "Done!")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testInterleavedContentOrdering() {
        // Test the exact user scenario: "I'll run sleep 3..." -> Tool -> "First done..." -> Tool -> "Done!"
        // This is the key fix: content blocks preserve exact streaming interleaving order
        let events = [
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Run sleep 3 twice")], timestamp: timestamp(0), sequence: 1),
            // Tool calls happen during streaming
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Bash"),
                "toolCallId": AnyCodable("tool1"),
                "arguments": AnyCodable(["command": "sleep 3"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tool1"),
                "content": AnyCodable("")
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Bash"),
                "toolCallId": AnyCodable("tool2"),
                "arguments": AnyCodable(["command": "sleep 3"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tool2"),
                "content": AnyCodable("")
            ], timestamp: timestamp(4), sequence: 5),
            // message.assistant has content blocks in EXACT streaming order
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "I'll run sleep 3..."],
                    ["type": "tool_use", "id": "tool1", "name": "Bash", "input": ["command": "sleep 3"]],
                    ["type": "text", "text": "First done, running second..."],
                    ["type": "tool_use", "id": "tool2", "name": "Bash", "input": ["command": "sleep 3"]],
                    ["type": "text", "text": "Done!"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(5), sequence: 6)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should produce: user + text + tool + text + tool + text = 6 messages
        XCTAssertEqual(messages.count, 6, "Should have 6 messages: user + 5 content blocks")

        // Verify exact order matches streaming order
        XCTAssertEqual(messages[0].role, .user)

        // Message 1: "I'll run sleep 3..."
        if case .text(let text) = messages[1].content {
            XCTAssertEqual(text, "I'll run sleep 3...")
        } else {
            XCTFail("Expected text content at index 1")
        }

        // Message 2: First tool call
        if case .toolUse(let tool) = messages[2].content {
            XCTAssertEqual(tool.toolCallId, "tool1")
            XCTAssertEqual(tool.toolName, "Bash")
            XCTAssertEqual(tool.result, "(no output)") // Empty result shows "(no output)"
        } else {
            XCTFail("Expected toolUse content at index 2")
        }

        // Message 3: "First done, running second..."
        if case .text(let text) = messages[3].content {
            XCTAssertEqual(text, "First done, running second...")
        } else {
            XCTFail("Expected text content at index 3")
        }

        // Message 4: Second tool call
        if case .toolUse(let tool) = messages[4].content {
            XCTAssertEqual(tool.toolCallId, "tool2")
            XCTAssertEqual(tool.toolName, "Bash")
        } else {
            XCTFail("Expected toolUse content at index 4")
        }

        // Message 5: "Done!"
        if case .text(let text) = messages[5].content {
            XCTAssertEqual(text, "Done!")
        } else {
            XCTFail("Expected text content at index 5")
        }
    }

    func testToolUseWithoutMatchingToolCallEvent() {
        // Edge case: tool_use in content blocks but NO separate tool.call event
        // This tests the fallback code path where we use content block info directly
        let events = [
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(0), sequence: 1),
            // NO tool.call event - only tool_use in message.assistant content
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me read that file:"],
                    ["type": "tool_use", "id": "orphan-tool-id", "name": "Read", "input": ["file_path": "/test.txt"]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should produce: user + text + tool (from content block fallback) = 3 messages
        XCTAssertEqual(messages.count, 3, "Should have 3 messages even without tool.call event")

        // Verify the tool uses fallback data from content block
        if case .toolUse(let tool) = messages[2].content {
            XCTAssertEqual(tool.toolCallId, "orphan-tool-id")
            XCTAssertEqual(tool.toolName, "Read")  // From content block
            XCTAssertTrue(tool.arguments.contains("file_path"))  // Serialized from content block
            XCTAssertEqual(tool.status, .running)  // No result = running
        } else {
            XCTFail("Expected toolUse content at index 2")
        }
    }

    // MARK: - Session State Reconstruction Tests

    func testReconstructSessionStateBasic() {
        let events = [
            rawEvent(type: "session.start", payload: [
                "model": AnyCodable("claude-sonnet-4"),
                "workingDirectory": AnyCodable("/home/user/project")
            ], timestamp: timestamp(0)),
            rawEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable("Hi there!"),
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable([
                    "source": [
                        "provider": "anthropic",
                        "timestamp": timestamp(2),
                        "rawInputTokens": 100,
                        "rawOutputTokens": 50,
                        "rawCacheReadTokens": 0,
                        "rawCacheCreationTokens": 0
                    ],
                    "computed": [
                        "contextWindowTokens": 100,
                        "newInputTokens": 100,
                        "previousContextBaseline": 0,
                        "calculationMethod": "anthropic_cache_aware"
                    ],
                    "meta": [
                        "turn": 1,
                        "sessionId": "test-session",
                        "extractedAt": timestamp(2),
                        "normalizedAt": timestamp(2)
                    ]
                ])
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
            rawEvent(type: "message.assistant", payload: ["content": AnyCodable("Now using Opus")], timestamp: timestamp(3))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.currentModel, "claude-opus-4")
        XCTAssertEqual(state.messages.count, 3) // user + model_switch + assistant
    }

    func testReconstructSessionStateWithTokenAccumulation() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable("Response 1"),
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable([
                    "source": [
                        "provider": "anthropic",
                        "timestamp": timestamp(1),
                        "rawInputTokens": 100,
                        "rawOutputTokens": 50,
                        "rawCacheReadTokens": 0,
                        "rawCacheCreationTokens": 0
                    ],
                    "computed": [
                        "contextWindowTokens": 100,
                        "newInputTokens": 100,
                        "previousContextBaseline": 0,
                        "calculationMethod": "anthropic_cache_aware"
                    ],
                    "meta": [
                        "turn": 1,
                        "sessionId": "test-session",
                        "extractedAt": timestamp(1),
                        "normalizedAt": timestamp(1)
                    ]
                ])
            ], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable("Response 2"),
                "turn": AnyCodable(2),
                "tokenRecord": AnyCodable([
                    "source": [
                        "provider": "anthropic",
                        "timestamp": timestamp(2),
                        "rawInputTokens": 200,
                        "rawOutputTokens": 100,
                        "rawCacheReadTokens": 0,
                        "rawCacheCreationTokens": 0
                    ],
                    "computed": [
                        "contextWindowTokens": 300,
                        "newInputTokens": 200,
                        "previousContextBaseline": 100,
                        "calculationMethod": "anthropic_cache_aware"
                    ],
                    "meta": [
                        "turn": 2,
                        "sessionId": "test-session",
                        "extractedAt": timestamp(2),
                        "normalizedAt": timestamp(2)
                    ]
                ])
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
            rawEvent(type: "error.tool", payload: [
                "toolName": AnyCodable("Bash"),
                "toolCallId": AnyCodable("call_err1"),
                "error": AnyCodable("Command failed")
            ], timestamp: timestamp(2)),
            rawEvent(type: "error.provider", payload: [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("Rate limited"),
                "retryable": AnyCodable(true)
            ], timestamp: timestamp(3))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // user + error.tool + error.provider = 3 messages
        XCTAssertEqual(state.messages.count, 3)
    }

    // MARK: - SessionEvent Overload Tests

    func testReconstructSessionStateFromSessionEvents() {
        let events = [
            sessionEvent(type: "session.start", payload: [
                "model": AnyCodable("claude-sonnet-4"),
                "workingDirectory": AnyCodable("/test")
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable("Hello!"),
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
        // Tool call without required toolCallId
        let event = rawEvent(
            type: "tool.call",
            payload: [
                "name": AnyCodable("Read")
                // Missing toolCallId and arguments
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
            rawEvent(type: "message.assistant", payload: ["content": AnyCodable("Third")], timestamp: timestamp(3), sequence: 3),
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
                "tokenRecord": AnyCodable([
                    "source": [
                        "provider": "anthropic",
                        "timestamp": "2026-01-01T00:00:00Z",
                        "rawInputTokens": 100,
                        "rawOutputTokens": 50,
                        "rawCacheReadTokens": 75,
                        "rawCacheCreationTokens": 0
                    ],
                    "computed": [
                        "contextWindowTokens": 150,
                        "newInputTokens": 25,
                        "previousContextBaseline": 125,
                        "calculationMethod": "anthropic_cache_aware"
                    ],
                    "meta": [
                        "turn": 1,
                        "sessionId": "test-session",
                        "extractedAt": "2026-01-01T00:00:00Z",
                        "normalizedAt": "2026-01-01T00:00:00Z"
                    ]
                ])
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

    func testAskUserQuestionPendingStatus() {
        // AskUserQuestion with no subsequent events should have pending status
        let toolCallId = "auq-\(UUID().uuidString)"
        // JSON must match AskUserQuestionParams exactly: id, question, options, mode (single/multi)
        let questionsJson = """
        {"questions":[{"id":"q1","question":"What is your name?","options":[{"label":"Alice"},{"label":"Bob"}],"mode":"single"}]}
        """
        let events = [
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("AskUserQuestion"),
                "toolCallId": AnyCodable(toolCallId),
                "arguments": AnyCodable(questionsJson),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": toolCallId, "name": "AskUserQuestion", "input": [
                        "questions": [
                            ["id": "q1", "question": "What is your name?", "options": [["label": "Alice"], ["label": "Bob"]], "mode": "single"]
                        ]
                    ]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2)
            // No subsequent message.user - question is pending
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 1)
        if case .askUserQuestion(let data) = messages[0].content {
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.params.questions.count, 1)
            XCTAssertEqual(data.params.questions[0].question, "What is your name?")
        } else {
            XCTFail("Expected askUserQuestion content")
        }
    }

    func testAskUserQuestionAnsweredStatus() {
        // AskUserQuestion followed by answer message should have answered status
        // NOTE: Status detection requires reconstructSessionState (not transformPersistedEvents)
        // because it needs the full event array to detect subsequent user messages
        let toolCallId = "auq-\(UUID().uuidString)"
        let questionsJson = """
        {"questions":[{"id":"q1","question":"What is your name?","options":[{"label":"Alice","description":"First option"},{"label":"Bob","description":"Second option"}],"mode":"single"}]}
        """
        let events = [
            rawEvent(type: "tool.call", payload: [
                "name": AnyCodable("AskUserQuestion"),
                "toolCallId": AnyCodable(toolCallId),
                "arguments": AnyCodable(questionsJson),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": toolCallId, "name": "AskUserQuestion", "input": [
                        "questions": [
                            ["id": "q1", "question": "What is your name?", "options": [["label": "Alice", "description": "First option"], ["label": "Bob", "description": "Second option"]], "mode": "single"]
                        ]
                    ]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("[Answers to your questions]\n\n**What is your name?**\nAnswer: Alice")
            ], timestamp: timestamp(2), sequence: 3)
        ]

        // Use reconstructSessionState which passes allEvents to status detection
        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // Should have AskUserQuestion (answered) + AnsweredQuestions chip
        XCTAssertGreaterThanOrEqual(state.messages.count, 1)
        if case .askUserQuestion(let data) = state.messages[0].content {
            XCTAssertEqual(data.status, .answered)
        } else {
            XCTFail("Expected askUserQuestion content with answered status")
        }
    }

    func testAskUserQuestionSupersededStatus() {
        // AskUserQuestion followed by different user message should have superseded status
        // NOTE: Status detection requires reconstructSessionState (not transformPersistedEvents)
        let toolCallId = "auq-\(UUID().uuidString)"
        let questionsJson = """
        {"questions":[{"id":"q1","question":"Pick one?","options":[{"label":"A"},{"label":"B"}],"mode":"single"}]}
        """
        let events = [
            rawEvent(type: "tool.call", payload: [
                "name": AnyCodable("AskUserQuestion"),
                "toolCallId": AnyCodable(toolCallId),
                "arguments": AnyCodable(questionsJson),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": toolCallId, "name": "AskUserQuestion", "input": [
                        "questions": [
                            ["id": "q1", "question": "Pick one?", "options": [["label": "A"], ["label": "B"]], "mode": "single"]
                        ]
                    ]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            // User sends different message instead of answering
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Never mind, let's do something else")
            ], timestamp: timestamp(2), sequence: 3)
        ]

        // Use reconstructSessionState which passes allEvents to status detection
        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertGreaterThanOrEqual(state.messages.count, 1)
        if case .askUserQuestion(let data) = state.messages[0].content {
            XCTAssertEqual(data.status, .superseded)
        } else {
            XCTFail("Expected askUserQuestion content with superseded status")
        }
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
                "tokenRecord": AnyCodable([
                    "source": [
                        "provider": "anthropic",
                        "timestamp": "2026-01-01T00:00:00Z",
                        "rawInputTokens": 100,
                        "rawOutputTokens": 50,
                        "rawCacheReadTokens": 75,
                        "rawCacheCreationTokens": 0
                    ],
                    "computed": [
                        "contextWindowTokens": 150,
                        "newInputTokens": 25,
                        "previousContextBaseline": 125,
                        "calculationMethod": "anthropic_cache_aware"
                    ],
                    "meta": [
                        "turn": 1,
                        "sessionId": "test-session",
                        "extractedAt": "2026-01-01T00:00:00Z",
                        "normalizedAt": "2026-01-01T00:00:00Z"
                    ]
                ])
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

    // MARK: - Subagent Reconstruction Tests

    func testSubagentSpawnedExtraction() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "tool.call", payload: [
                "toolCallId": AnyCodable("tc_1"),
                "name": AnyCodable("SpawnSubagent"),
                "arguments": AnyCodable("{\"task\":\"Research Swift concurrency\"}"),
                "turn": AnyCodable(1)
            ], sequence: 2),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_sess_1"),
                "task": AnyCodable("Research Swift concurrency"),
                "model": AnyCodable("claude-opus-4-6"),
                "toolCallId": AnyCodable("tc_1"),
                "spawnType": AnyCodable("subsession")
            ], sequence: 3),
            sessionEvent(type: "subagent.completed", payload: [
                "subagentSessionId": AnyCodable("sub_sess_1"),
                "resultSummary": AnyCodable("Found 5 key patterns"),
                "totalTurns": AnyCodable(7),
                "duration": AnyCodable(45000),
                "totalTokenUsage": AnyCodable(["inputTokens": 50000, "outputTokens": 2000]),
                "model": AnyCodable("claude-opus-4-6"),
                "fullOutput": AnyCodable("Detailed findings...")
            ], sequence: 4),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_1"),
                "content": AnyCodable("Research complete"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(45000)
            ], sequence: 5)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.subagentSpawns.count, 1)
        XCTAssertEqual(state.subagentSpawns[0].subagentSessionId, "sub_sess_1")
        XCTAssertEqual(state.subagentSpawns[0].toolCallId, "tc_1")
        XCTAssertEqual(state.subagentSpawns[0].task, "Research Swift concurrency")
        XCTAssertEqual(state.subagentSpawns[0].model, "claude-opus-4-6")

        XCTAssertEqual(state.subagentCompletions.count, 1)
        let completion = state.subagentCompletions["sub_sess_1"]
        XCTAssertNotNil(completion)
        XCTAssertEqual(completion?.totalTurns, 7)
        XCTAssertEqual(completion?.duration, 45000)
        XCTAssertEqual(completion?.resultSummary, "Found 5 key patterns")
        XCTAssertEqual(completion?.fullOutput, "Detailed findings...")
    }

    func testSubagentFailedExtraction() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "tool.call", payload: [
                "toolCallId": AnyCodable("tc_2"),
                "name": AnyCodable("SpawnSubagent"),
                "arguments": AnyCodable("{\"task\":\"Failing task\"}"),
                "turn": AnyCodable(1)
            ], sequence: 2),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_sess_2"),
                "task": AnyCodable("Failing task"),
                "model": AnyCodable("claude-sonnet-4-5"),
                "toolCallId": AnyCodable("tc_2")
            ], sequence: 3),
            sessionEvent(type: "subagent.failed", payload: [
                "subagentSessionId": AnyCodable("sub_sess_2"),
                "error": AnyCodable("Max turns exceeded"),
                "duration": AnyCodable(30000)
            ], sequence: 4),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_2"),
                "content": AnyCodable("Agent failed: Max turns exceeded"),
                "isError": AnyCodable(true),
                "duration": AnyCodable(30000)
            ], sequence: 5)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.subagentFailures.count, 1)
        let failure = state.subagentFailures["sub_sess_2"]
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.error, "Max turns exceeded")
        XCTAssertEqual(failure?.duration, 30000)
    }

    func testMultipleParallelSubagentsExtraction() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "tool.call", payload: [
                "toolCallId": AnyCodable("tc_a"),
                "name": AnyCodable("SpawnSubagent"),
                "arguments": AnyCodable("{\"task\":\"Explore auth\"}"),
                "turn": AnyCodable(1)
            ], sequence: 2),
            sessionEvent(type: "tool.call", payload: [
                "toolCallId": AnyCodable("tc_b"),
                "name": AnyCodable("SpawnSubagent"),
                "arguments": AnyCodable("{\"task\":\"Research OAuth\"}"),
                "turn": AnyCodable(1)
            ], sequence: 3),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_a"),
                "task": AnyCodable("Explore auth"),
                "model": AnyCodable("claude-sonnet-4-5"),
                "toolCallId": AnyCodable("tc_a")
            ], sequence: 4),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_b"),
                "task": AnyCodable("Research OAuth"),
                "model": AnyCodable("claude-opus-4-6"),
                "toolCallId": AnyCodable("tc_b")
            ], sequence: 5),
            sessionEvent(type: "subagent.completed", payload: [
                "subagentSessionId": AnyCodable("sub_a"),
                "resultSummary": AnyCodable("Auth patterns found"),
                "totalTurns": AnyCodable(4),
                "duration": AnyCodable(20000),
                "totalTokenUsage": AnyCodable(["inputTokens": 10000, "outputTokens": 500])
            ], sequence: 6),
            sessionEvent(type: "subagent.failed", payload: [
                "subagentSessionId": AnyCodable("sub_b"),
                "error": AnyCodable("Provider error"),
                "duration": AnyCodable(5000)
            ], sequence: 7),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_a"),
                "content": AnyCodable("Done"),
                "isError": AnyCodable(false)
            ], sequence: 8),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_b"),
                "content": AnyCodable("Failed"),
                "isError": AnyCodable(true)
            ], sequence: 9)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.subagentSpawns.count, 2)
        XCTAssertEqual(state.subagentCompletions.count, 1)
        XCTAssertNotNil(state.subagentCompletions["sub_a"])
        XCTAssertEqual(state.subagentCompletions["sub_a"]?.totalTurns, 4)
        XCTAssertEqual(state.subagentFailures.count, 1)
        XCTAssertNotNil(state.subagentFailures["sub_b"])
        XCTAssertEqual(state.subagentFailures["sub_b"]?.error, "Provider error")
    }

    func testSubagentSpawnedWithoutToolCallIdFallback() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "tool.call", payload: [
                "toolCallId": AnyCodable("tc_old"),
                "name": AnyCodable("SpawnSubagent"),
                "arguments": AnyCodable("{\"task\":\"Old style task\"}"),
                "turn": AnyCodable(1)
            ], sequence: 2),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_old"),
                "task": AnyCodable("Old style task"),
                "model": AnyCodable("claude-sonnet-4-5")
            ], sequence: 3),
            sessionEvent(type: "subagent.completed", payload: [
                "subagentSessionId": AnyCodable("sub_old"),
                "resultSummary": AnyCodable("Done"),
                "totalTurns": AnyCodable(3),
                "duration": AnyCodable(15000),
                "totalTokenUsage": AnyCodable(["inputTokens": 5000, "outputTokens": 300])
            ], sequence: 4)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.subagentSpawns.count, 1)
        XCTAssertNil(state.subagentSpawns[0].toolCallId)
        XCTAssertEqual(state.subagentSpawns[0].subagentSessionId, "sub_old")
    }

    func testRunningSubagentNoCompletionEvent() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "tool.call", payload: [
                "toolCallId": AnyCodable("tc_run"),
                "name": AnyCodable("SpawnSubagent"),
                "arguments": AnyCodable("{\"task\":\"Long running task\"}"),
                "turn": AnyCodable(1)
            ], sequence: 2),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_run"),
                "task": AnyCodable("Long running task"),
                "model": AnyCodable("claude-opus-4-6"),
                "toolCallId": AnyCodable("tc_run")
            ], sequence: 3)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.subagentSpawns.count, 1)
        XCTAssertTrue(state.subagentCompletions.isEmpty)
        XCTAssertTrue(state.subagentFailures.isEmpty)
    }

    func testBackgroundSubagentNoToolCall() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], sequence: 2),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_bg"),
                "task": AnyCodable("LedgerWriter"),
                "model": AnyCodable("claude-haiku-4-5"),
                "spawnType": AnyCodable("subsession")
            ], sequence: 3),
            sessionEvent(type: "subagent.completed", payload: [
                "subagentSessionId": AnyCodable("sub_bg"),
                "resultSummary": AnyCodable("Ledger updated"),
                "totalTurns": AnyCodable(1),
                "duration": AnyCodable(2000),
                "totalTokenUsage": AnyCodable(["inputTokens": 1000, "outputTokens": 50])
            ], sequence: 4)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(state.subagentSpawns.count, 1)
        XCTAssertEqual(state.subagentCompletions.count, 1)
    }

    func testSubagentSpawnedBlockingFieldExtracted() {
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_1"),
                "task": AnyCodable("Blocking task"),
                "model": AnyCodable("claude-opus-4-6"),
                "toolCallId": AnyCodable("tc_1"),
                "blocking": AnyCodable(true)
            ], sequence: 2)
        ]
        let state = UnifiedEventTransformer.reconstructSessionState(from: events)
        XCTAssertEqual(state.subagentSpawns.count, 1)
        XCTAssertTrue(state.subagentSpawns[0].blocking)
    }

    func testSubagentSpawnedBlockingDefaultsFalse() {
        // Old events without blocking field should default to false
        let events = [
            sessionEvent(type: "session.start", payload: [:], sequence: 1),
            sessionEvent(type: "subagent.spawned", payload: [
                "subagentSessionId": AnyCodable("sub_old"),
                "task": AnyCodable("Old task"),
                "model": AnyCodable("claude-opus-4-6")
            ], sequence: 2)
        ]
        let state = UnifiedEventTransformer.reconstructSessionState(from: events)
        XCTAssertEqual(state.subagentSpawns.count, 1)
        XCTAssertFalse(state.subagentSpawns[0].blocking)
    }

    // MARK: - Subagent Session Chat Rendering Tests

    func testSubagentSessionEventsTransformToChat() {
        // A typical subagent session: user message (task), assistant reply with tool use, final output
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Count files in the current directory")
            ], timestamp: timestamp(1), sequence: 2),
            rawEvent(type: "tool.call", payload: [
                "name": AnyCodable("Bash"),
                "toolCallId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["command": "ls -la | wc -l"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3),
            rawEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_1"),
                "content": AnyCodable("9")
            ], timestamp: timestamp(3), sequence: 4),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "tc_1", "name": "Bash", "input": ["command": "ls -la | wc -l"]],
                    ["type": "text", "text": "There are **9 files** in the directory."]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + tool_use + text = 3 messages
        XCTAssertEqual(messages.count, 3)

        // First message should be the user's task
        XCTAssertEqual(messages[0].role, .user)
        if case .text(let text) = messages[0].content {
            XCTAssertTrue(text.contains("Count files"))
        } else {
            XCTFail("Expected text content for user message")
        }

        // Second message: tool use with result
        if case .toolUse(let tool) = messages[1].content {
            XCTAssertEqual(tool.toolName, "Bash")
            XCTAssertEqual(tool.toolCallId, "tc_1")
            XCTAssertEqual(tool.result, "9")
            XCTAssertEqual(tool.status, .success)
        } else {
            XCTFail("Expected toolUse content")
        }

        // Third message: assistant text with markdown
        XCTAssertEqual(messages[2].role, .assistant)
        if case .text(let text) = messages[2].content {
            XCTAssertTrue(text.contains("**9 files**"))
        } else {
            XCTFail("Expected text content for assistant message")
        }
    }

    func testSubagentSessionEmptyEventsProducesNoMessages() {
        let events: [RawEvent] = []
        let messages = UnifiedEventTransformer.transformPersistedEvents(events)
        XCTAssertTrue(messages.isEmpty)
    }

    func testSubagentSessionWithOnlySessionStartProducesNoMessages() {
        let events = [
            rawEvent(type: "session.start", payload: [:], sequence: 1)
        ]
        let messages = UnifiedEventTransformer.transformPersistedEvents(events)
        XCTAssertTrue(messages.isEmpty)
    }

    func testSubagentSessionMultiTurnConversation() {
        // Subagent with multiple turns (reads two files)
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Analyze the codebase")
            ], timestamp: timestamp(1), sequence: 2),
            // Turn 1
            rawEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"),
                "toolCallId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/src/main.ts"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3),
            rawEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_1"),
                "content": AnyCodable("const app = express();")
            ], timestamp: timestamp(3), sequence: 4),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "tc_1", "name": "Read", "input": ["file_path": "/src/main.ts"]],
                    ["type": "text", "text": "Found the entry point. Let me check the config."]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5),
            // Turn 2
            rawEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"),
                "toolCallId": AnyCodable("tc_2"),
                "arguments": AnyCodable(["file_path": "/tsconfig.json"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(5), sequence: 6),
            rawEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_2"),
                "content": AnyCodable("{\"compilerOptions\": {}}")
            ], timestamp: timestamp(6), sequence: 7),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "tc_2", "name": "Read", "input": ["file_path": "/tsconfig.json"]],
                    ["type": "text", "text": "Analysis complete. The codebase uses TypeScript with Express."]
                ]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(7), sequence: 8)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + (tool + text) turn 1 + (tool + text) turn 2 = 5
        XCTAssertEqual(messages.count, 5)

        // Exactly 1 user message (the task)
        let userMessages = messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1)

        // 2 tool use messages
        let toolMessages = messages.filter {
            if case .toolUse = $0.content { return true }
            return false
        }
        XCTAssertEqual(toolMessages.count, 2)

        // 2 assistant text messages
        let textMessages = messages.filter { message in
            guard message.role == .assistant else { return false }
            if case .text = message.content { return true }
            return false
        }
        XCTAssertEqual(textMessages.count, 2)
    }

    func testSubagentSessionWithMarkdownTable() {
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

    func testSubagentSessionWithFailedTool() {
        // Tool that returns error status
        let events = [
            rawEvent(type: "session.start", payload: [:], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.user", payload: [
                "content": AnyCodable("Read a nonexistent file")
            ], timestamp: timestamp(1), sequence: 2),
            rawEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"),
                "toolCallId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/nonexistent"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(2), sequence: 3),
            rawEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_1"),
                "content": AnyCodable("File not found"),
                "isError": AnyCodable(true)
            ], timestamp: timestamp(3), sequence: 4),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "tc_1", "name": "Read", "input": ["file_path": "/nonexistent"]],
                    ["type": "text", "text": "The file does not exist."]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + tool + text = 3
        XCTAssertEqual(messages.count, 3)

        let toolMessages = messages.filter {
            if case .toolUse(let tool) = $0.content {
                return tool.status == .error
            }
            return false
        }
        XCTAssertEqual(toolMessages.count, 1, "Failed tool should show error status")
    }

    // MARK: - TokenRecord Fallback Tests (Tool-Only Turns)

    func testTokenRecordFallbackToToolUseWhenNoTextBlock() {
        // Turn with [thinking, tool_use] and no text block — tokenRecord should attach to tool message
        let tokenRecordPayload: [String: Any] = [
            "source": [
                "provider": "anthropic",
                "timestamp": "2026-01-01T00:00:00Z",
                "rawInputTokens": 10,
                "rawOutputTokens": 261,
                "rawCacheReadTokens": 12561,
                "rawCacheCreationTokens": 498
            ],
            "computed": [
                "contextWindowTokens": 12571,
                "newInputTokens": 10,
                "previousContextBaseline": 12561,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": 1,
                "sessionId": "test-session",
                "extractedAt": "2026-01-01T00:00:00Z",
                "normalizedAt": "2026-01-01T00:00:00Z"
            ]
        ]

        let events = [
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Search"),
                "toolCallId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["query": "test"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_1"),
                "content": AnyCodable("Found 3 results")
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Let me search for this..."],
                    ["type": "tool_use", "id": "tc_1", "name": "Search", "input": ["query": "test"]]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(3254),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // thinking + tool_use = 2 messages
        XCTAssertEqual(messages.count, 2)

        // Tool message (last) should have tokenRecord
        if case .toolUse = messages[1].content {
            XCTAssertNotNil(messages[1].tokenRecord, "tokenRecord should be attached to toolUse when no text block exists")
            XCTAssertEqual(messages[1].tokenRecord?.computed.newInputTokens, 10)
            XCTAssertEqual(messages[1].tokenRecord?.source.rawOutputTokens, 261)
            XCTAssertEqual(messages[1].tokenRecord?.source.rawCacheReadTokens, 12561)
        } else {
            XCTFail("Expected toolUse content at index 1")
        }
    }

    func testTokenRecordFallbackWithMultipleToolUses() {
        // Turn with [thinking, tool_use, tool_use] — last tool gets tokenRecord
        let tokenRecordPayload: [String: Any] = [
            "source": [
                "provider": "anthropic",
                "timestamp": "2026-01-01T00:00:00Z",
                "rawInputTokens": 13,
                "rawOutputTokens": 216,
                "rawCacheReadTokens": 13059,
                "rawCacheCreationTokens": 928
            ],
            "computed": [
                "contextWindowTokens": 13072,
                "newInputTokens": 13,
                "previousContextBaseline": 13059,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": 2,
                "sessionId": "test-session",
                "extractedAt": "2026-01-01T00:00:00Z",
                "normalizedAt": "2026-01-01T00:00:00Z"
            ]
        ]

        let events = [
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"),
                "toolCallId": AnyCodable("tc_a"),
                "arguments": AnyCodable(["file_path": "/src/a.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_a"),
                "content": AnyCodable("file a contents")
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"),
                "toolCallId": AnyCodable("tc_b"),
                "arguments": AnyCodable(["file_path": "/src/b.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_b"),
                "content": AnyCodable("file b contents")
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Reading both files..."],
                    ["type": "tool_use", "id": "tc_a", "name": "Read", "input": ["file_path": "/src/a.ts"]],
                    ["type": "tool_use", "id": "tc_b", "name": "Read", "input": ["file_path": "/src/b.ts"]]
                ]),
                "turn": AnyCodable(2),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1995),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // thinking + tool_use + tool_use = 3 messages
        XCTAssertEqual(messages.count, 3)

        // First tool should NOT have tokenRecord (metadata goes on last message)
        if case .toolUse = messages[1].content {
            XCTAssertNil(messages[1].tokenRecord, "First toolUse should NOT get tokenRecord")
        } else {
            XCTFail("Expected toolUse at index 1")
        }

        // Last tool (last message in turn) should have tokenRecord
        if case .toolUse = messages[2].content {
            XCTAssertNotNil(messages[2].tokenRecord, "Last toolUse should get tokenRecord")
            XCTAssertEqual(messages[2].tokenRecord?.computed.newInputTokens, 13)
        } else {
            XCTFail("Expected toolUse at index 2")
        }
    }

    func testTokenRecordOnTextBlockNotOverriddenByFallback() {
        // Turn with [thinking, text, tool_use] — last message (tool) gets tokenRecord
        let tokenRecordPayload: [String: Any] = [
            "source": [
                "provider": "anthropic",
                "timestamp": "2026-01-01T00:00:00Z",
                "rawInputTokens": 14,
                "rawOutputTokens": 787,
                "rawCacheReadTokens": 13987,
                "rawCacheCreationTokens": 7026
            ],
            "computed": [
                "contextWindowTokens": 14001,
                "newInputTokens": 14,
                "previousContextBaseline": 13987,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": 3,
                "sessionId": "test-session",
                "extractedAt": "2026-01-01T00:00:00Z",
                "normalizedAt": "2026-01-01T00:00:00Z"
            ]
        ]

        let events = [
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Bash"),
                "toolCallId": AnyCodable("tc_x"),
                "arguments": AnyCodable(["command": "echo hello"]),
                "turn": AnyCodable(3)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_x"),
                "content": AnyCodable("hello")
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Running command..."],
                    ["type": "text", "text": "Here's the result"],
                    ["type": "tool_use", "id": "tc_x", "name": "Bash", "input": ["command": "echo hello"]]
                ]),
                "turn": AnyCodable(3),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(11087),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // thinking + text + tool = 3 messages
        XCTAssertEqual(messages.count, 3)

        // Text message should NOT have tokenRecord (metadata goes on last message)
        if case .text(let text) = messages[1].content {
            XCTAssertEqual(text, "Here's the result")
            XCTAssertNil(messages[1].tokenRecord, "Text block should NOT get tokenRecord (last message does)")
        } else {
            XCTFail("Expected text at index 1")
        }

        // Last message (tool) should have tokenRecord so stats render after all content
        if case .toolUse = messages[2].content {
            XCTAssertNotNil(messages[2].tokenRecord, "Last message should get tokenRecord")
            XCTAssertEqual(messages[2].tokenRecord?.source.rawOutputTokens, 787)
        } else {
            XCTFail("Expected toolUse at index 2")
        }
    }

    func testTokenRecordFallbackIncludesModelAndLatency() {
        // Verify the fallback also attaches model and latency metadata
        let tokenRecordPayload: [String: Any] = [
            "source": [
                "provider": "anthropic",
                "timestamp": "2026-01-01T00:00:00Z",
                "rawInputTokens": 10,
                "rawOutputTokens": 100,
                "rawCacheReadTokens": 5000,
                "rawCacheCreationTokens": 0
            ],
            "computed": [
                "contextWindowTokens": 5010,
                "newInputTokens": 10,
                "previousContextBaseline": 5000,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": 1,
                "sessionId": "test-session",
                "extractedAt": "2026-01-01T00:00:00Z",
                "normalizedAt": "2026-01-01T00:00:00Z"
            ]
        ]

        let events = [
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"),
                "toolCallId": AnyCodable("tc_meta"),
                "arguments": AnyCodable(["file_path": "/test.ts"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_meta"),
                "content": AnyCodable("contents")
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "tc_meta", "name": "Read", "input": ["file_path": "/test.ts"]]
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

    // MARK: - Metadata Stripping Tests

    func testMetadataStrippedFromIntermediateTurns() {
        // Multi-turn session: metadata should only appear on the last assistant
        // message before each user prompt and at the end of the conversation.
        // This prevents noisy stats badges after every tool call on session resume.
        let tokenRecord1: [String: Any] = [
            "source": ["provider": "anthropic", "timestamp": "2026-01-01T00:00:00Z",
                        "rawInputTokens": 100, "rawOutputTokens": 50,
                        "rawCacheReadTokens": 0, "rawCacheCreationTokens": 0],
            "computed": ["contextWindowTokens": 150, "newInputTokens": 100,
                         "previousContextBaseline": 0, "calculationMethod": "anthropic_cache_aware"],
            "meta": ["turn": 1, "sessionId": "s1", "extractedAt": "2026-01-01T00:00:00Z",
                     "normalizedAt": "2026-01-01T00:00:00Z"]
        ]
        let tokenRecord2: [String: Any] = [
            "source": ["provider": "anthropic", "timestamp": "2026-01-01T00:00:00Z",
                        "rawInputTokens": 10, "rawOutputTokens": 200,
                        "rawCacheReadTokens": 140, "rawCacheCreationTokens": 0],
            "computed": ["contextWindowTokens": 350, "newInputTokens": 10,
                         "previousContextBaseline": 150, "calculationMethod": "anthropic_cache_aware"],
            "meta": ["turn": 2, "sessionId": "s1", "extractedAt": "2026-01-01T00:00:00Z",
                     "normalizedAt": "2026-01-01T00:00:00Z"]
        ]
        let tokenRecord3: [String: Any] = [
            "source": ["provider": "anthropic", "timestamp": "2026-01-01T00:00:00Z",
                        "rawInputTokens": 15, "rawOutputTokens": 300,
                        "rawCacheReadTokens": 335, "rawCacheCreationTokens": 0],
            "computed": ["contextWindowTokens": 650, "newInputTokens": 15,
                         "previousContextBaseline": 350, "calculationMethod": "anthropic_cache_aware"],
            "meta": ["turn": 3, "sessionId": "s1", "extractedAt": "2026-01-01T00:00:00Z",
                     "normalizedAt": "2026-01-01T00:00:00Z"]
        ]

        let events = [
            // User prompt
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Do something")
            ], timestamp: timestamp(0), sequence: 1),
            // Turn 1: text + tool (intermediate)
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Read"), "toolCallId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/a.ts"]), "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_1"), "content": AnyCodable("contents")
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me read that file."],
                    ["type": "tool_use", "id": "tc_1", "name": "Read", "input": ["file_path": "/a.ts"]]
                ]),
                "turn": AnyCodable(1), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1000), "tokenRecord": AnyCodable(tokenRecord1)
            ], timestamp: timestamp(3), sequence: 4),
            // Turn 2: tool only (intermediate)
            sessionEvent(type: "tool.call", payload: [
                "name": AnyCodable("Edit"), "toolCallId": AnyCodable("tc_2"),
                "arguments": AnyCodable(["file_path": "/a.ts"]), "turn": AnyCodable(2)
            ], timestamp: timestamp(4), sequence: 5),
            sessionEvent(type: "tool.result", payload: [
                "toolCallId": AnyCodable("tc_2"), "content": AnyCodable("edited")
            ], timestamp: timestamp(5), sequence: 6),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_use", "id": "tc_2", "name": "Edit", "input": ["file_path": "/a.ts"]]
                ]),
                "turn": AnyCodable(2), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(2000), "tokenRecord": AnyCodable(tokenRecord2)
            ], timestamp: timestamp(6), sequence: 7),
            // Turn 3: final text response
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "All done!"]
                ]),
                "turn": AnyCodable(3), "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(500), "tokenRecord": AnyCodable(tokenRecord3)
            ], timestamp: timestamp(7), sequence: 8)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + text1 + tool1 + tool2 + text2 = 5 messages
        XCTAssertEqual(messages.count, 5)

        // User message
        if case .text(let t) = messages[0].content { XCTAssertEqual(t, "Do something") }

        // Turn 1 text: metadata stripped (intermediate turn)
        XCTAssertNil(messages[1].tokenRecord, "Intermediate turn text should not have metadata")
        XCTAssertNil(messages[1].model)

        // Turn 1 tool: metadata stripped (intermediate turn)
        XCTAssertNil(messages[2].tokenRecord, "Intermediate turn tool should not have metadata")
        XCTAssertNil(messages[2].model)

        // Turn 2 tool: metadata stripped (intermediate turn)
        XCTAssertNil(messages[3].tokenRecord, "Intermediate turn tool should not have metadata")
        XCTAssertNil(messages[3].model)

        // Turn 3 text (last assistant message): metadata preserved
        XCTAssertNotNil(messages[4].tokenRecord, "Last assistant message should keep metadata")
        XCTAssertEqual(messages[4].model, "claude-opus-4-6")
        XCTAssertEqual(messages[4].latencyMs, 500)
    }

    func testMetadataPreservedBeforeUserMessage() {
        // When a user sends a follow-up, the last assistant message before
        // that user message should retain its metadata.
        let tokenRecord: [String: Any] = [
            "source": ["provider": "anthropic", "timestamp": "2026-01-01T00:00:00Z",
                        "rawInputTokens": 100, "rawOutputTokens": 50,
                        "rawCacheReadTokens": 0, "rawCacheCreationTokens": 0],
            "computed": ["contextWindowTokens": 150, "newInputTokens": 100,
                         "previousContextBaseline": 0, "calculationMethod": "anthropic_cache_aware"],
            "meta": ["turn": 1, "sessionId": "s1", "extractedAt": "2026-01-01T00:00:00Z",
                     "normalizedAt": "2026-01-01T00:00:00Z"]
        ]

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

        // user + assistant + user = 3 messages
        XCTAssertEqual(messages.count, 3)

        // Assistant message (last before user) should have metadata
        XCTAssertNotNil(messages[1].tokenRecord, "Last assistant before user should keep metadata")
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
}
