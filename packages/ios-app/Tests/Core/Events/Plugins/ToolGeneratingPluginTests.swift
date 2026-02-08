import XCTest
@testable import TronMobile

final class ToolGeneratingPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "agent.tool_generating",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "toolName": "Write",
                "toolCallId": "tc1"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolGeneratingPlugin.parse(from: json)

        XCTAssertEqual(event.type, "agent.tool_generating")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.toolName, "Write")
        XCTAssertEqual(event.data.toolCallId, "tc1")
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "agent.tool_generating",
            "sessionId": "session-456",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "toolName": "Bash",
                "toolCallId": "tc2"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolGeneratingPlugin.parse(from: json)
        let result = ToolGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? ToolGeneratingPlugin.Result else {
            XCTFail("Expected ToolGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.toolName, "Bash")
        XCTAssertEqual(toolResult.toolCallId, "tc2")
    }

    func testTransformMinimalPayload() throws {
        let json = """
        {
            "type": "agent.tool_generating",
            "data": {
                "toolName": "Read",
                "toolCallId": "tc3"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolGeneratingPlugin.parse(from: json)
        let result = ToolGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? ToolGeneratingPlugin.Result else {
            XCTFail("Expected ToolGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.toolName, "Read")
        XCTAssertEqual(toolResult.toolCallId, "tc3")
    }
}
