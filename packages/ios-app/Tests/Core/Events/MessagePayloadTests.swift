import XCTest
@testable import TronMobile

final class AssistantMessagePayloadTests: XCTestCase {

    func testParsesContentBlockArray() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Hello world"] as [String: Any]
            ] as [[String: Any]])
        ]

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertNotNil(parsed.contentBlocks)
        XCTAssertEqual(parsed.contentBlocks?.count, 1)
        XCTAssertEqual(parsed.contentBlocks?[0]["text"] as? String, "Hello world")
    }

    func testMissingContentReturnsNilBlocks() {
        let payload: [String: AnyCodable] = [
            "turn": AnyCodable(1)
        ]

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertNil(parsed.contentBlocks)
    }

    func testNonArrayContentReturnsNilBlocks() {
        // Content as a plain string (not array) should yield nil — no legacy handling
        let payload: [String: AnyCodable] = [
            "content": AnyCodable("plain string")
        ]

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertNil(parsed.contentBlocks)
    }

    func testEmptyArrayContentReturnsEmptyBlocks() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([[String: Any]]())
        ]

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertNotNil(parsed.contentBlocks)
        XCTAssertEqual(parsed.contentBlocks?.count, 0)
    }

    func testParsesTurn() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([[String: Any]]()),
            "turn": AnyCodable(3)
        ]

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed.turn, 3)
    }

    func testDefaultTurnIsOne() {
        let payload: [String: AnyCodable] = [:]

        let parsed = AssistantMessagePayload(from: payload)

        XCTAssertEqual(parsed.turn, 1)
    }
}

final class UserMessagePayloadTests: XCTestCase {

    func testParsesModernImageFormat() {
        let imageData = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                [
                    "type": "image",
                    "data": imageData,
                    "mimeType": "image/jpeg"
                ] as [String: Any]
            ] as [[String: Any]])
        ]

        let parsed = UserMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.attachments?.count, 1)
        XCTAssertEqual(parsed?.attachments?[0].type, .image)
        XCTAssertEqual(parsed?.attachments?[0].mimeType, "image/jpeg")
    }

    func testUnrecognizedImageFormatSkipped() {
        let imageData = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                [
                    "type": "image",
                    "source": [
                        "data": imageData,
                        "media_type": "image/png"
                    ] as [String: Any]
                ] as [String: Any]
            ] as [[String: Any]])
        ]

        let parsed = UserMessagePayload(from: payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.attachments?.count ?? 0, 0)
    }
}
