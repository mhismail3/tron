import XCTest
@testable import TronMobile

final class UnifiedEventTransformerCharacterizationTests: UnifiedEventTransformerTestCase {
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
}
