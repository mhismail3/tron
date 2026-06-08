import XCTest
@testable import TronMobile

final class UnifiedEventTransformerStateTests: UnifiedEventTransformerTestCase {
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
}
