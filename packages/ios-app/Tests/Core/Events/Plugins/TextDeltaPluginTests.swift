import XCTest
@testable import TronMobile

final class TextDeltaPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "delta": "Hello, world!",
                "messageIndex": 5
            }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)

        XCTAssertEqual(event.type, "agent.text_delta")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.delta, "Hello, world!")
        XCTAssertEqual(event.data.messageIndex, 5)
    }

    func testParseWithoutOptionalFields() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "data": {
                "delta": "Just text"
            }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)

        XCTAssertEqual(event.type, "agent.text_delta")
        XCTAssertNil(event.sessionId)
        XCTAssertNil(event.timestamp)
        XCTAssertEqual(event.data.delta, "Just text")
        XCTAssertNil(event.data.messageIndex)
    }

    func testParseMalformedJSON() {
        let json = """
        {
            "type": "agent.text_delta"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TextDeltaPlugin.parse(from: json))
    }

    func testParseEmptyDelta() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "data": {
                "delta": ""
            }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)
        XCTAssertEqual(event.data.delta, "")
    }

    // MARK: - Session ID Tests

    func testSessionIdExtraction() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-456",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)
        XCTAssertEqual(TextDeltaPlugin.sessionId(from: event), "session-456")
    }

    func testSessionIdNilWhenMissing() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)
        XCTAssertNil(TextDeltaPlugin.sessionId(from: event))
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-789",
            "data": {
                "delta": "Transformed text",
                "messageIndex": 10
            }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)
        let result = TextDeltaPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let textResult = result as? TextDeltaPlugin.Result else {
            XCTFail("Expected TextDeltaPlugin.Result")
            return
        }

        XCTAssertEqual(textResult.delta, "Transformed text")
        XCTAssertEqual(textResult.messageIndex, 10)
    }

    func testTransformWithUnicodeContent() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "data": {
                "delta": "Hello 👋 World 🌍"
            }
        }
        """.data(using: .utf8)!

        let event = try TextDeltaPlugin.parse(from: json)
        let result = TextDeltaPlugin.transform(event) as? TextDeltaPlugin.Result

        XCTAssertEqual(result?.delta, "Hello 👋 World 🌍")
    }

    // MARK: - Parity Tests

    func testParityWithLegacyTextDeltaEvent() throws {
        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "parity-test-session",
            "timestamp": "2025-01-26T12:00:00Z",
            "data": {
                "delta": "Parity test content",
                "messageIndex": 42
            }
        }
        """.data(using: .utf8)!

        // Parse with plugin system
        let pluginEvent = try TextDeltaPlugin.parse(from: json)

        // Parse with legacy system
        let legacyEvent = try JSONDecoder().decode(TextDeltaEvent.self, from: json)

        // Verify parity
        XCTAssertEqual(TextDeltaPlugin.sessionId(from: pluginEvent), legacyEvent.sessionId)
        XCTAssertEqual(pluginEvent.data.delta, legacyEvent.delta)
        XCTAssertEqual(pluginEvent.data.messageIndex, legacyEvent.data.messageIndex)
    }
}
