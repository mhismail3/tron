import XCTest
@testable import TronMobile

final class UnifiedEventTransformerTokenMetadataTests: UnifiedEventTransformerTestCase {
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
}
