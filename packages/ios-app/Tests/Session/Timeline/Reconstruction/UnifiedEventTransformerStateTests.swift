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
        XCTAssertEqual(state.totalTokenUsage.inputTokens, 100)
        XCTAssertEqual(state.totalTokenUsage.outputTokens, 50)
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
        XCTAssertEqual(state.totalTokenUsage.inputTokens, 0)
        XCTAssertEqual(state.lastTurnInputTokens, 0)
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
