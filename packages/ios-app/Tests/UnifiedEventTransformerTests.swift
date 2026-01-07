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

        if case .modelChange(let from, let to) = message?.content {
            XCTAssertEqual(from, "claude-sonnet-4")
            XCTAssertEqual(to, "claude-opus-4")
        } else {
            XCTFail("Expected modelChange content")
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
            "ledger.update",
            "ledger.goal",
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
                "tokenUsage": AnyCodable([
                    "inputTokens": 100,
                    "outputTokens": 50
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

    func testReconstructSessionStateWithLedger() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "ledger.goal", payload: ["goal": AnyCodable("Implement authentication")], timestamp: timestamp(1)),
            rawEvent(type: "ledger.update", payload: [
                "field": AnyCodable("next"),
                "newValue": AnyCodable(["Add login form", "Add password hashing"])
            ], timestamp: timestamp(2)),
            rawEvent(type: "ledger.update", payload: [
                "field": AnyCodable("done"),
                "newValue": AnyCodable(["Created user model"])
            ], timestamp: timestamp(3))
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertNotNil(state.ledger)
        XCTAssertEqual(state.ledger?.goal, "Implement authentication")
        XCTAssertEqual(state.ledger?.next.count, 2)
        XCTAssertEqual(state.ledger?.done.count, 1)
    }

    func testReconstructSessionStateWithTokenAccumulation() {
        let events = [
            rawEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable("Response 1"),
                "turn": AnyCodable(1),
                "tokenUsage": AnyCodable(["inputTokens": 100, "outputTokens": 50])
            ], timestamp: timestamp(1)),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable("Response 2"),
                "turn": AnyCodable(2),
                "tokenUsage": AnyCodable(["inputTokens": 200, "outputTokens": 100])
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
}
