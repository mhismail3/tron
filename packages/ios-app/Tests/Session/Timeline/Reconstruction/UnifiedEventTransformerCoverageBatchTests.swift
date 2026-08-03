import XCTest
@testable import TronMobile

final class UnifiedEventTransformerCoverageBatchTests: UnifiedEventTransformerTestCase {
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
        for (offset, fixture) in fixtures.enumerated() {
            let (eventType, payload) = fixture
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
        let standaloneRenderableTypes = fixtures.keys.filter {
            $0 != .toolInvocationStarted && $0 != .toolInvocationCompleted
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

    func testEveryCachedEventTypeHasExplicitReconstructionDisposition() {
        let rendered = Set(renderableEventFixtures().keys)
        let stateHandled: Set<SessionEventType> = [
            .messageDeleted,
            .compactBoundary
        ]
        let consumedThroughAssistantMessage: Set<SessionEventType> = [
            .toolInvocationStarted,
            .toolInvocationCompleted,
            .streamThinkingComplete
        ]
        let intentionallyNoStateImpact: Set<SessionEventType> = [
            // Session lifecycle/tree facts stay in server reconstruction metadata,
            // CachedSession, or raw durable diagnostics rather than mounted state.
            .sessionStart,
            .sessionEnd,
            .sessionFork,
            // Turn boundaries and provider audits remain available for
            // diagnostics but do not rebuild timeline messages.
            .streamTurnStart,
            .streamTurnEnd,
            .modelProviderRequest
        ]

        let accounted = rendered
            .union(stateHandled)
            .union(consumedThroughAssistantMessage)
            .union(intentionallyNoStateImpact)
        let expected = Set(SessionEventType.serverDurableCases)
            .union([.streamThinkingComplete])
        let missing = expected
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
        // - tool.invocation.started events provide tool details (name, arguments, turn)
        // - tool.invocation.completed events provide results
        // - The order comes from message.assistant's content array, not timestamps
        let events = [
            sessionEvent(type: "session.start", payload: ["model": AnyCodable("claude-sonnet-4")], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hi")], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.invocation.started", payload: ["toolName": AnyCodable("process_run"), "invocationId": AnyCodable("c1"), "arguments": AnyCodable([:]), "turn": AnyCodable(1)], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "tool.invocation.completed", payload: ["invocationId": AnyCodable("c1"), "content": AnyCodable("result"), "isError": AnyCodable(false), "duration": AnyCodable(10)], timestamp: timestamp(3), sequence: 4),
            // message.assistant content blocks reflect exact streaming order: tool_invocation then text
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_invocation", "id": "c1", "name": "process_run", "input": [:]],
                    ["type": "text", "text": "Done!"]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // user + tool.invocation.started (from content block) + text (from content block) = 3 messages
        // Order comes from message.assistant's content array
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant) // tool_invocation block -> tool.invocation.started with result
        XCTAssertEqual(messages[2].role, .assistant) // text block

        // Verify tool invocation has result attached
        if case .toolInvocation(let invocation) = messages[1].content {
            XCTAssertEqual(invocation.identity.toolName, "process_run")
            XCTAssertEqual(invocation.result, "result")
            XCTAssertEqual(invocation.status, .success)
        } else {
            XCTFail("Expected tool invocation content")
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
            // Tool invocations happen during streaming
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("invocation1"),
                "arguments": AnyCodable(["command": "sleep 3"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("invocation1"),
                "content": AnyCodable(""),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("invocation2"),
                "arguments": AnyCodable(["command": "sleep 3"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("invocation2"),
                "content": AnyCodable(""),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(4), sequence: 5),
            // message.assistant has content blocks in EXACT streaming order
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "I'll run sleep 3..."],
                    ["type": "tool_invocation", "id": "invocation1", "name": "process_run", "input": ["command": "sleep 3"]],
                    ["type": "text", "text": "First done, running second..."],
                    ["type": "tool_invocation", "id": "invocation2", "name": "process_run", "input": ["command": "sleep 3"]],
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

        // Message 2: First tool invocation
        if case .toolInvocation(let invocation) = messages[2].content {
            XCTAssertEqual(invocation.id, "invocation1")
            XCTAssertEqual(invocation.identity.toolName, "process_run")
            XCTAssertEqual(invocation.result, "(no output)") // Empty result shows "(no output)"
        } else {
            XCTFail("Expected tool invocation content at index 2")
        }

        // Message 3: "First done, running second..."
        if case .text(let text) = messages[3].content {
            XCTAssertEqual(text, "First done, running second...")
        } else {
            XCTFail("Expected text content at index 3")
        }

        // Message 4: Second tool invocation
        if case .toolInvocation(let invocation) = messages[4].content {
            XCTAssertEqual(invocation.id, "invocation2")
            XCTAssertEqual(invocation.identity.toolName, "process_run")
        } else {
            XCTFail("Expected tool invocation content at index 4")
        }

        // Message 5: "Done!"
        if case .text(let text) = messages[5].content {
            XCTAssertEqual(text, "Done!")
        } else {
            XCTFail("Expected text content at index 5")
        }
    }

    func testToolInvocationUseWithoutMatchingToolInvocationEventDoesNotInferOldName() {
        // Edge case: tool_invocation in content blocks but NO enriched tool event.
        // iOS preserves the invocation shell, but must not synthesize identity
        // from the content-block name.
        let events = [
            sessionEvent(type: "message.user", payload: ["content": AnyCodable("Hello")], timestamp: timestamp(0), sequence: 1),
            // NO tool.invocation.started event - only tool_invocation in message.assistant content
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me read that file:"],
                    ["type": "tool_invocation", "id": "orphan-tool-id", "name": "process_run", "input": ["file_path": "/test.txt"]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Should produce: user + text + tool shell = 3 messages
        XCTAssertEqual(messages.count, 3, "Should have 3 messages even without tool.invocation.started event")

        // Verify arguments survive, while identity remains generic.
        if case .toolInvocation(let invocation) = messages[2].content {
            XCTAssertEqual(invocation.id, "orphan-tool-id")
            XCTAssertNil(invocation.identity.toolName)
            XCTAssertTrue(invocation.identity.isEmpty)
            XCTAssertTrue(invocation.arguments.contains("file_path"))  // Serialized from content block
            XCTAssertEqual(invocation.status, .running)  // No result = running
        } else {
            XCTFail("Expected tool invocation content at index 2")
        }
    }
}
