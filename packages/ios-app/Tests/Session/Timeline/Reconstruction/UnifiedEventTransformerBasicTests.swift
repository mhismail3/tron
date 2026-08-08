import XCTest
@testable import TronMobile

final class UnifiedEventTransformerBasicTests: UnifiedEventTransformerTestCase {
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

    // MARK: - Tool Call Tests

    func testTransformToolInvocation() {
        let event = rawEvent(
            type: "tool.invocation.started",
            payload: [
                "invocationId": AnyCodable("call_123"),
                "toolName": AnyCodable("process_run"),
                "arguments": AnyCodable(["file_path": "/src/main.ts"]),
                "turn": AnyCodable(1)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .assistant)

        if case .toolInvocation(let invocation) = message?.content {
            XCTAssertEqual(invocation.identity.toolName, "process_run")
            XCTAssertEqual(invocation.id, "call_123")
        } else {
            XCTFail("Expected tool invocation content")
        }
    }

    func testUserInputRequestAndAnswerReconstructAsDurableNativeMessages() throws {
        let events = [
            rawEvent(
                id: "assistant-question",
                type: "message.assistant",
                payload: [
                    "content": AnyCodable([[
                        "type": "tool_invocation",
                        "id": "question-1",
                        "name": "request_user_input",
                        "input": [String: Any]()
                    ]]),
                    "turn": AnyCodable(1),
                    "model": AnyCodable("test-model"),
                    "stopReason": AnyCodable("tool_use")
                ],
                sequence: 1
            ),
            rawEvent(
                id: "question-start",
                type: "tool.invocation.started",
                payload: [
                    "invocationId": AnyCodable("question-1"),
                    "toolName": AnyCodable("request_user_input"),
                    "arguments": AnyCodable("""
                    {"questions":[{"header":"Format","id":"format","question":"Which format?","options":[{"label":"Markdown","description":"Markdown file"},{"label":"HTML","description":"HTML file"}]}]}
                    """),
                    "turn": AnyCodable(1)
                ],
                sequence: 2
            ),
            rawEvent(
                id: "question-complete",
                type: "tool.invocation.completed",
                payload: [
                    "invocationId": AnyCodable("question-1"),
                    "toolName": AnyCodable("request_user_input"),
                    "content": AnyCodable("Question presented"),
                    "isError": AnyCodable(false),
                    "duration": AnyCodable(1)
                ],
                sequence: 3
            ),
            rawEvent(
                id: "question-answer",
                type: "message.user",
                payload: [
                    "content": AnyCodable("Format: Markdown"),
                    "messageKind": AnyCodable("user_input_answer"),
                    "toolName": AnyCodable("request_user_input_answer"),
                    "invocationId": AnyCodable("question-1"),
                    "answers": AnyCodable([[
                        "questionId": "format",
                        "selectedLabel": "Markdown"
                    ]])
                ],
                sequence: 4
            )
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 2)
        guard case .userInputRequest(let request) = messages[0].content else {
            return XCTFail("Expected native request")
        }
        XCTAssertEqual(request.status, .answered)
        XCTAssertEqual(request.answers.first?.selectedLabel, "Markdown")
        guard case .userInputAnswer(let answer) = messages[1].content else {
            return XCTFail("Expected native answer")
        }
        XCTAssertEqual(answer.invocationId, "question-1")
        XCTAssertEqual(answer.answers.first?.selectedLabel, "Markdown")
    }

    // MARK: - Tool Result Tests

    func testTransformToolResult() {
        let event = rawEvent(
            type: "tool.invocation.completed",
            payload: [
                "invocationId": AnyCodable("call_123"),
                "content": AnyCodable("File contents here..."),
                "isError": AnyCodable(false),
                "duration": AnyCodable(150)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.role, .tool)

        if case .toolResult(let result) = message?.content {
            XCTAssertEqual(result.id, "call_123")
            XCTAssertFalse(result.isError)
        } else {
            XCTFail("Expected tool result content")
        }
    }

    func testTransformToolResultWithError() {
        let event = rawEvent(
            type: "tool.invocation.completed",
            payload: [
                "invocationId": AnyCodable("call_456"),
                "content": AnyCodable("File not found"),
                "isError": AnyCodable(true),
                "duration": AnyCodable(42)
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)

        if case .toolResult(let result) = message?.content {
            XCTAssertTrue(result.isError)
        } else {
            XCTFail("Expected tool result content")
        }
    }

}
