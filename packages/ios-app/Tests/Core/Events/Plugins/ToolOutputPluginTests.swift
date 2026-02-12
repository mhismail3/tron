import XCTest
@testable import TronMobile

final class ToolOutputPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "agent.tool_output",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "toolCallId": "tool-call-abc",
                "output": "partial stdout chunk"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolOutputPlugin.parse(from: json)

        XCTAssertEqual(event.type, "agent.tool_output")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.toolCallId, "tool-call-abc")
        XCTAssertEqual(event.data.output, "partial stdout chunk")
    }

    func testParseWithoutSessionId() throws {
        let json = """
        {
            "type": "agent.tool_output",
            "data": {
                "toolCallId": "tool-1",
                "output": "chunk"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolOutputPlugin.parse(from: json)

        XCTAssertNil(event.sessionId)
        XCTAssertEqual(event.data.toolCallId, "tool-1")
        XCTAssertEqual(event.data.output, "chunk")
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "agent.tool_output",
            "sessionId": "session-456",
            "data": {
                "toolCallId": "tool-call-def",
                "output": "streaming output text"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolOutputPlugin.parse(from: json)
        let result = ToolOutputPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let outputResult = result as? ToolOutputPlugin.Result else {
            XCTFail("Expected ToolOutputPlugin.Result")
            return
        }

        XCTAssertEqual(outputResult.toolCallId, "tool-call-def")
        XCTAssertEqual(outputResult.output, "streaming output text")
    }
}
