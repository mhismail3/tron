import XCTest
@testable import TronMobile

final class UnifiedEventTransformerTokenMetadataTests: UnifiedEventTransformerTestCase {
    // MARK: - Final Response Metadata

    func testRepeatedDeliveryMetadataProducesOneResumePrelude() {
        let continuation = AnyCodable([
            "deliveries": [
                [
                    "deliveryId": "delivery-1",
                    "sourceKind": "worker_result",
                    "sourceWorkerId": "wait-ux-smoke",
                    "sourceWorkerName": "Wait UX Smoke Test",
                    "sourceInvocationId": "worker-run-1",
                    "wakePolicy": "wake",
                    "boundary": "next_run",
                    "triggeredWake": true,
                    "redelivery": false
                ] as [String: Any]
            ]
        ] as [String: Any])
        let events = [
            sessionEvent(
                type: "message.assistant",
                payload: [
                    "content": AnyCodable([
                        ["type": "text", "text": "Reading the exact result."]
                    ]),
                    "turn": AnyCodable(4),
                    "agentDeliveryContinuation": continuation
                ],
                timestamp: timestamp(0),
                sequence: 1
            ),
            sessionEvent(
                type: "message.assistant",
                payload: [
                    "content": AnyCodable([
                        ["type": "text", "text": "The worker completed."]
                    ]),
                    "turn": AnyCodable(5),
                    "agentDeliveryContinuation": continuation
                ],
                timestamp: timestamp(1),
                sequence: 2
            )
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)
        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(
            messages.filter(\.isDeliveryProvenanceOnly).count,
            1
        )
        XCTAssertEqual(
            state.messages.filter(\.isDeliveryProvenanceOnly).count,
            1
        )
        XCTAssertEqual(
            messages.first(where: \.isDeliveryProvenanceOnly)?
                .agentDeliveryProvenance.first?.deliveryId,
            "delivery-1"
        )
    }

    func testTextOnlyResponseAttachesExactlyOneMetadataRow() {
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 75,
            turn: 1,
            contextWindowTokens: 175,
            newInputTokens: 25,
            previousContextBaseline: 150
        )
        let events = [
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Planning the response"],
                    ["type": "text", "text": "First paragraph."],
                    ["type": "thinking", "thinking": "Checking the response"],
                    ["type": "text", "text": "Final paragraph."]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1_250),
                "stopReason": AnyCodable("stop_sequence"),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(0), sequence: 1)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages.filter { $0.isFinalAssistantResponse }.count, 1)
        XCTAssertEqual(messages.filter { $0.finalAssistantResponseMetadata != nil }.count, 1)

        for index in 0..<3 {
            XCTAssertFalse(messages[index].isFinalAssistantResponse)
            XCTAssertNil(messages[index].finalAssistantResponseMetadata)
            XCTAssertNil(messages[index].tokenRecord)
            XCTAssertNil(messages[index].model)
            XCTAssertNil(messages[index].latencyMs)
        }

        guard case .text(let text) = messages[3].content else {
            return XCTFail("Expected the final text block to own response metadata")
        }
        XCTAssertEqual(text, "Final paragraph.")
        XCTAssertTrue(messages[3].isFinalAssistantResponse)
        XCTAssertNotNil(messages[3].finalAssistantResponseMetadata)
        XCTAssertEqual(messages[3].tokenRecord?.computed.newInputTokens, 25)
        XCTAssertEqual(messages[3].tokenRecord?.source.rawOutputTokens, 50)
        XCTAssertEqual(messages[3].model, "claude-opus-4-6")
        XCTAssertEqual(messages[3].latencyMs, 1_250)
    }

    // MARK: - Intermediate Response Suppression

    func testToolOnlyResponseSuppressesMetadataFromThinkingAndTools() {
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
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("tc_a"),
                "arguments": AnyCodable(["file_path": "/src/a.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_a"),
                "content": AnyCodable("file a contents"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("tc_b"),
                "arguments": AnyCodable(["file_path": "/src/b.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_b"),
                "content": AnyCodable("file b contents"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Reading both files..."],
                    ["type": "tool_invocation", "id": "tc_a", "name": "process_run", "input": ["file_path": "/src/a.ts"]],
                    ["type": "tool_invocation", "id": "tc_b", "name": "process_run", "input": ["file_path": "/src/b.ts"]]
                ]),
                "turn": AnyCodable(2),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1_995),
                "stopReason": AnyCodable("tool_invocation"),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(4), sequence: 5)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 3)
        if case .thinking = messages[0].content,
           case .toolInvocation = messages[1].content,
           case .toolInvocation = messages[2].content {
            assertNoResponseMetadata(messages)
        } else {
            XCTFail("Expected thinking followed by two tool invocations")
        }
    }

    func testTextBeforeToolSuppressesMetadataEvenWhenStopReasonIsEndTurn() {
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
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("tc_x"),
                "arguments": AnyCodable(["command": "echo hello"]),
                "turn": AnyCodable(3)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_x"),
                "content": AnyCodable("hello"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "thinking", "thinking": "Running command..."],
                    ["type": "text", "text": "Here's the result"],
                    ["type": "tool_invocation", "id": "tc_x", "name": "process_run", "input": ["command": "echo hello"]]
                ]),
                "turn": AnyCodable(3),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(11_087),
                "stopReason": AnyCodable("end_turn"),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 3)
        guard case .text(let text) = messages[1].content,
              case .toolInvocation = messages[2].content else {
            return XCTFail("Expected text before the tool invocation")
        }
        XCTAssertEqual(text, "Here's the result")
        assertNoResponseMetadata(messages)
    }

    func testToolBeforeTextSuppressesMetadataWithInvocationStopReason() {
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 20,
            outputTokens: 80,
            turn: 4,
            contextWindowTokens: 200,
            newInputTokens: 20,
            previousContextBaseline: 180
        )
        let events = [
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("tc_order"),
                "arguments": AnyCodable(["command": "true"]),
                "turn": AnyCodable(4)
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_order"),
                "content": AnyCodable("ok"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(5)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_invocation", "id": "tc_order", "name": "process_run", "input": ["command": "true"]],
                    ["type": "text", "text": "This text is still part of the tool response."]
                ]),
                "turn": AnyCodable(4),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(900),
                "stopReason": AnyCodable("tool_invocation"),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 2)
        guard case .toolInvocation = messages[0].content,
              case .text(let text) = messages[1].content else {
            return XCTFail("Expected tool invocation before text")
        }
        XCTAssertEqual(text, "This text is still part of the tool response.")
        assertNoResponseMetadata(messages)
    }

    func testInterruptedTextResponseSuppressesMetadata() {
        let tokenRecordPayload = makeTokenRecordPayload(
            inputTokens: 30,
            outputTokens: 12,
            turn: 1,
            contextWindowTokens: 42,
            newInputTokens: 30
        )
        let events = [
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Partial response"]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(400),
                "stopReason": AnyCodable("end_turn"),
                "interrupted": AnyCodable(true),
                "tokenRecord": AnyCodable(tokenRecordPayload)
            ], timestamp: timestamp(0), sequence: 1)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 1)
        if case .text(let text) = messages[0].content {
            XCTAssertEqual(text, "Partial response")
            assertNoResponseMetadata(messages)
        } else {
            XCTFail("Expected interrupted text to remain visible")
        }
    }

    // MARK: - Accounting and Preservation

    func testOnlyFinalTextResponseReceivesMetadataWhileStateAggregatesEveryPayload() {
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
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Do something")
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("tc_1"),
                "arguments": AnyCodable(["file_path": "/a.ts"]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_1"),
                "content": AnyCodable("contents"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "Let me read that file."],
                    ["type": "tool_invocation", "id": "tc_1", "name": "process_run", "input": ["file_path": "/a.ts"]]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(1_000),
                "stopReason": AnyCodable("end_turn"),
                "tokenRecord": AnyCodable(tokenRecord1)
            ], timestamp: timestamp(3), sequence: 4),
            sessionEvent(type: "tool.invocation.started", payload: [
                "toolName": AnyCodable("process_run"),
                "invocationId": AnyCodable("tc_2"),
                "arguments": AnyCodable(["file_path": "/a.ts"]),
                "turn": AnyCodable(2)
            ], timestamp: timestamp(4), sequence: 5),
            sessionEvent(type: "tool.invocation.completed", payload: [
                "invocationId": AnyCodable("tc_2"),
                "content": AnyCodable("edited"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(10)
            ], timestamp: timestamp(5), sequence: 6),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "tool_invocation", "id": "tc_2", "name": "process_run", "input": ["file_path": "/a.ts"]]
                ]),
                "turn": AnyCodable(2),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(2_000),
                "stopReason": AnyCodable("tool_invocation"),
                "tokenRecord": AnyCodable(tokenRecord2)
            ], timestamp: timestamp(6), sequence: 7),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "text", "text": "All done!"]
                ]),
                "turn": AnyCodable(3),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(500),
                "stopReason": AnyCodable("end_turn"),
                "tokenRecord": AnyCodable(tokenRecord3)
            ], timestamp: timestamp(7), sequence: 8)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)
        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages.filter { $0.finalAssistantResponseMetadata != nil }.count, 1)
        for index in 0..<4 {
            XCTAssertNil(messages[index].finalAssistantResponseMetadata)
            XCTAssertNil(messages[index].tokenRecord)
        }
        XCTAssertTrue(messages[4].isFinalAssistantResponse)
        XCTAssertEqual(messages[4].tokenRecord?.source.rawOutputTokens, 300)
        XCTAssertEqual(messages[4].model, "claude-opus-4-6")
        XCTAssertEqual(messages[4].latencyMs, 500)

        XCTAssertEqual(state.messages.filter { $0.finalAssistantResponseMetadata != nil }.count, 1)
        XCTAssertEqual(state.totalTokenUsage.inputTokens, 125)
        XCTAssertEqual(state.totalTokenUsage.outputTokens, 550)
        XCTAssertEqual(state.totalTokenUsage.cacheReadTokens, 475)
        XCTAssertEqual(state.lastTurnInputTokens, 650)
    }

    func testFinalTextMetadataPersistsAcrossFollowingUserMessage() {
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
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-opus-4-6"),
                "latency": AnyCodable(800),
                "stopReason": AnyCodable("end_turn"),
                "tokenRecord": AnyCodable(tokenRecord)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Thanks")
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[1].isFinalAssistantResponse)
        XCTAssertNotNil(messages[1].finalAssistantResponseMetadata)
        XCTAssertNotNil(messages[1].tokenRecord)
        XCTAssertEqual(messages[1].model, "claude-opus-4-6")
        XCTAssertEqual(messages[1].latencyMs, 800)
        XCTAssertNil(messages[2].finalAssistantResponseMetadata)
    }

    private func assertNoResponseMetadata(
        _ messages: [ChatMessage],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            messages.allSatisfy { !$0.isFinalAssistantResponse },
            "Intermediate response items must not be marked final",
            file: file,
            line: line
        )
        XCTAssertTrue(
            messages.allSatisfy { $0.finalAssistantResponseMetadata == nil },
            "Intermediate response items must not expose a metadata row",
            file: file,
            line: line
        )
        XCTAssertTrue(
            messages.allSatisfy {
                $0.tokenRecord == nil
                    && $0.model == nil
                    && $0.latencyMs == nil
            },
            "Intermediate response items must not retain presentation metadata",
            file: file,
            line: line
        )
    }
}
