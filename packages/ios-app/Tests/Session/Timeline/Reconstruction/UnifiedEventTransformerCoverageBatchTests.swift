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
            .metadataUpdate, .metadataTag
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
}
