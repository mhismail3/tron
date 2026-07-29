import XCTest
@testable import TronMobile

final class AssistantMessagePayloadTests: XCTestCase {

    /// The Rust payload (`events/types/payloads/message.rs::AssistantMessagePayload`)
    /// declares `content`, `turn`, `model`, and `stopReason` non-optional.
    /// Every fixture in this file MUST include them; missing any field →
    /// `init?` returns nil, guarded by the "missing" tests below.
    private func validPayload(
        content: AnyCodable,
        turn: Int = 1,
        model: String = "claude-sonnet-4",
        stopReason: String = "end_turn"
    ) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "content": content,
            "turn": AnyCodable(turn),
            "model": AnyCodable(model),
            "stopReason": AnyCodable(stopReason)
        ]
        return payload
    }

    func testParsesContentBlockArray() {
        let payload = validPayload(content: AnyCodable([
            ["type": "text", "text": "Hello world"] as [String: Any]
        ] as [[String: Any]]))

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.contentBlocks.count, 1)
        XCTAssertEqual(parsed?.contentBlocks[0]["text"] as? String, "Hello world")
    }

    func testParsesDeliveryOnlyContinuationProvenance() {
        var payload = validPayload(content: AnyCodable([
            ["type": "text", "text": "The worker finished."] as [String: Any]
        ] as [[String: Any]]))
        payload["agentDeliveryContinuation"] = AnyCodable([
            "deliveries": [
                [
                    "deliveryId": "delivery-1",
                    "sourceKind": "worker_result",
                    "sourceSessionId": "session-source",
                    "sourceInvocationId": "worker-run-1",
                    "redelivery": true
                ] as [String: Any]
            ]
        ] as [String: Any])

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed?.agentDeliveryProvenance.count, 1)
        XCTAssertEqual(parsed?.agentDeliveryProvenance.first?.deliveryId, "delivery-1")
        XCTAssertEqual(parsed?.agentDeliveryProvenance.first?.sourceKind, "worker_result")
        XCTAssertEqual(parsed?.agentDeliveryProvenance.first?.sourceInvocationId, "worker-run-1")
        XCTAssertEqual(parsed?.agentDeliveryProvenance.first?.redelivery, true)
    }

    func testTextWithoutToolsIsEligibleForFinalResponsePresentation() {
        let payload = validPayload(content: AnyCodable([
            ["type": "text", "text": "Final response"] as [String: Any]
        ] as [[String: Any]]), stopReason: "provider_specific_reason")

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed?.hasToolInvocations, false)
        XCTAssertEqual(parsed?.isFinalAssistantResponse, true)
    }

    func testToolBearingTextIsIneligibleRegardlessOfStopReason() {
        let payload = validPayload(content: AnyCodable([
            ["type": "text", "text": "I will inspect that"] as [String: Any],
            [
                "type": "tool_invocation",
                "id": "call-1",
                "name": "process_run",
                "input": ["command": "true"]
            ] as [String: Any]
        ] as [[String: Any]]), stopReason: "end_turn")

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed?.hasToolInvocations, true)
        XCTAssertEqual(parsed?.isFinalAssistantResponse, false)
    }

    func testInterruptedTextIsIneligibleForFinalResponsePresentation() {
        var payload = validPayload(content: AnyCodable([
            ["type": "text", "text": "Partial response"] as [String: Any]
        ] as [[String: Any]]))
        payload["interrupted"] = AnyCodable(true)

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed?.isFinalAssistantResponse, false)
    }

    func testMissingContentFailsDecode() {
        // `content` is non-optional on the Rust payload. Its absence
        // is a schema violation; init? must return nil.
        let payload: [String: AnyCodable] = [
            "turn": AnyCodable(1),
            "model": AnyCodable("claude-sonnet-4"),
            "stopReason": AnyCodable("end_turn")
        ]

        XCTAssertNil(AssistantMessagePayload(from: payload))
    }

    func testNonArrayContentFailsDecode() {
        // Content as a plain string (not array) is not a valid shape.
        // No historical-shape handling — init? returns nil.
        let payload: [String: AnyCodable] = [
            "content": AnyCodable("plain string"),
            "turn": AnyCodable(1),
            "model": AnyCodable("claude-sonnet-4"),
            "stopReason": AnyCodable("end_turn")
        ]

        XCTAssertNil(AssistantMessagePayload(from: payload))
    }

    func testEmptyArrayContentDecodesWithNoBlocks() {
        let payload = validPayload(content: AnyCodable([[String: Any]]()))

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.contentBlocks.count, 0)
    }

    func testParsesTurn() {
        let payload = validPayload(content: AnyCodable([[String: Any]]()), turn: 3)

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed?.turn, 3)
    }

    func testMissingTurnFailsDecode() {
        // `turn` is non-optional on the Rust payload.
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([[String: Any]]()),
            "model": AnyCodable("claude-sonnet-4"),
            "stopReason": AnyCodable("end_turn")
        ]

        XCTAssertNil(AssistantMessagePayload(from: payload))
    }

    func testMissingModelFailsDecode() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([[String: Any]]()),
            "turn": AnyCodable(1),
            "stopReason": AnyCodable("end_turn")
        ]

        XCTAssertNil(AssistantMessagePayload(from: payload))
    }

    func testMissingStopReasonFailsDecode() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([[String: Any]]()),
            "turn": AnyCodable(1),
            "model": AnyCodable("claude-sonnet-4")
        ]

        XCTAssertNil(AssistantMessagePayload(from: payload))
    }
}

final class ThinkingCompletePayloadTests: XCTestCase {
    func testReasoningSummaryUsesThinkingDisplayTitle() {
        XCTAssertEqual(ThinkingDisplayKind.thinking.title, "Thinking")
        XCTAssertEqual(ThinkingDisplayKind.reasoningSummary.title, "Reasoning Summary")
    }

    func testToDictionaryPersistsReasoningSummaryKind() {
        let payload = ThinkingCompletePayload(
            turnNumber: 7,
            content: "A provider-authored reasoning summary.",
            model: "gpt-5.5",
            kind: .reasoningSummary
        )

        let dict = payload.toDictionary()

        XCTAssertEqual(dict["kind"] as? String, "reasoning_summary")
    }

    func testToDictionaryOmitsDefaultThinkingKind() {
        let payload = ThinkingCompletePayload(
            turnNumber: 7,
            content: "Append-only thinking text.",
            model: "claude-sonnet-4",
            kind: .thinking
        )

        let dict = payload.toDictionary()

        XCTAssertNil(dict["kind"])
    }
}

final class UserMessagePayloadTests: XCTestCase {

    private func validPayload(content: AnyCodable, turn: Int = 1) -> [String: AnyCodable] {
        ["content": content, "turn": AnyCodable(turn)]
    }

    func testParsesModernImageFormat() {
        let imageData = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        let payload = validPayload(content: AnyCodable([
            [
                "type": "image",
                "data": imageData,
                "mimeType": "image/jpeg"
            ] as [String: Any]
        ] as [[String: Any]]))

        let parsed = UserMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.attachments?.count, 1)
        XCTAssertEqual(parsed?.attachments?[0].type, .image)
        XCTAssertEqual(parsed?.attachments?[0].mimeType, "image/jpeg")
    }

    func testUnrecognizedImageFormatSkipped() {
        let imageData = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        let payload = validPayload(content: AnyCodable([
            [
                "type": "image",
                "source": [
                    "data": imageData,
                    "media_type": "image/png"
                ] as [String: Any]
            ] as [String: Any]
        ] as [[String: Any]]))

        let parsed = UserMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.attachments?.count ?? 0, 0)
    }

    func testMissingTurnStillDecodes() {
        // Some persisted user messages only carry `content`. Reconstruction
        // must keep rendering those messages instead of dropping every user
        // bubble on resume.
        let payload: [String: AnyCodable] = [
            "content": AnyCodable("Hello")
        ]

        let parsed = UserMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.content, "Hello")
        XCTAssertNil(parsed?.turn)
    }
}
