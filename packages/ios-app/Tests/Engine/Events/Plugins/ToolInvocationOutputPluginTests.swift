import XCTest
@testable import TronMobile

final class ToolInvocationOutputPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "tool.invocation.output",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "invocationId": "tool-invocation-abc",
                "output": "partial stdout chunk"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationOutputPlugin.parse(from: json)

        XCTAssertEqual(event.type, "tool.invocation.output")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.invocationId, "tool-invocation-abc")
        XCTAssertEqual(event.data.output, "partial stdout chunk")
    }

    func testParseWithoutSessionId() throws {
        let json = """
        {
            "type": "tool.invocation.output",
            "data": {
                "invocationId": "tool-1",
                "output": "chunk"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationOutputPlugin.parse(from: json)

        XCTAssertNil(event.sessionId)
        XCTAssertEqual(event.data.invocationId, "tool-1")
        XCTAssertEqual(event.data.output, "chunk")
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "tool.invocation.output",
            "sessionId": "session-456",
            "data": {
                "invocationId": "tool-invocation-def",
                "output": "streaming output text"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationOutputPlugin.parse(from: json)
        let result = ToolInvocationOutputPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let outputResult = result as? ToolInvocationOutputPlugin.Result else {
            XCTFail("Expected ToolInvocationOutputPlugin.Result")
            return
        }

        XCTAssertEqual(outputResult.invocationId, "tool-invocation-def")
        XCTAssertEqual(outputResult.output, "streaming output text")
    }
}
