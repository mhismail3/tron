import XCTest
@testable import TronMobile

final class ToolInvocationGeneratingPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "tool.invocation.generating",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "toolName": "process_run",
                "invocationId": "tc1"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationGeneratingPlugin.parse(from: json)

        XCTAssertEqual(event.type, "tool.invocation.generating")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.toolName, "process_run")
        XCTAssertEqual(event.data.invocationId, "tc1")
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "tool.invocation.generating",
            "sessionId": "session-456",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "toolName": "process_run",
                "invocationId": "tc2"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationGeneratingPlugin.parse(from: json)
        let result = ToolInvocationGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? ToolInvocationGeneratingPlugin.Result else {
            XCTFail("Expected ToolInvocationGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.toolName, "process_run")
        XCTAssertEqual(toolResult.invocationId, "tc2")
        XCTAssertEqual(toolResult.timestamp, DateParser.parse("2025-01-26T10:00:00Z"))
    }

    func testTransformMinimalPayload() throws {
        let json = """
        {
            "type": "tool.invocation.generating",
            "data": {
                "toolName": "process_run",
                "invocationId": "tc3"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationGeneratingPlugin.parse(from: json)
        let result = ToolInvocationGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? ToolInvocationGeneratingPlugin.Result else {
            XCTFail("Expected ToolInvocationGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.toolName, "process_run")
        XCTAssertEqual(toolResult.invocationId, "tc3")
    }

    func testTransformCarriesServerOwnedPresentationHints() throws {
        let json = """
        {
            "type": "tool.invocation.generating",
            "data": {
                "toolName": "process_run",
                "invocationId": "tc4",
                "presentationHints": {
                    "displayName": "Shell Command",
                    "chipTitle": "Shell",
                    "icon": "terminal",
                    "themeColor": "#38BDF8"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationGeneratingPlugin.parse(from: json)
        let result = ToolInvocationGeneratingPlugin.transform(event) as? ToolInvocationGeneratingPlugin.Result

        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "Shell Command")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "Shell")
        XCTAssertEqual(result?.identity.presentationHints?["icon"]?.stringValue, "terminal")
        XCTAssertEqual(result?.identity.presentationHints?["themeColor"]?.stringValue, "#38BDF8")
    }
}
