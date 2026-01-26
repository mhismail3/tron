import XCTest
@testable import TronMobile

final class ToolEndPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "toolCallId": "tool-call-abc",
                "toolName": "Read",
                "success": true,
                "result": "File content here",
                "durationMs": 150
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)

        XCTAssertEqual(event.type, "agent.tool_end")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.toolCallId, "tool-call-abc")
        XCTAssertEqual(event.data.toolName, "Read")
        XCTAssertTrue(event.data.success)
        XCTAssertEqual(event.data.result, "File content here")
        XCTAssertEqual(event.data.durationMs, 150)
    }

    func testParseWithError() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "sessionId": "session-123",
            "data": {
                "toolCallId": "tool-call-xyz",
                "success": false,
                "error": "File not found"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)

        XCTAssertFalse(event.data.success)
        XCTAssertEqual(event.data.error, "File not found")
    }

    func testParseWithOutputAsString() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "data": {
                "toolCallId": "tool-1",
                "success": true,
                "output": "String output"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)

        XCTAssertEqual(event.data.output, "String output")
    }

    func testParseWithOutputAsContentBlockArray() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "data": {
                "toolCallId": "tool-2",
                "success": true,
                "output": [
                    {"type": "text", "text": "First part"},
                    {"type": "text", "text": " Second part"}
                ]
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)

        XCTAssertEqual(event.data.output, "First part Second part")
    }

    func testParseWithDetails() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "data": {
                "toolCallId": "tool-3",
                "success": true,
                "details": {
                    "screenshot": "base64data...",
                    "format": "png"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)

        XCTAssertEqual(event.data.details?.screenshot, "base64data...")
        XCTAssertEqual(event.data.details?.format, "png")
    }

    func testParseWithDurationField() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "data": {
                "toolCallId": "tool-4",
                "success": true,
                "duration": 500
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)

        XCTAssertEqual(event.data.duration, 500)
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "sessionId": "session-456",
            "data": {
                "toolCallId": "tool-call-def",
                "toolName": "Write",
                "success": true,
                "result": "File written successfully",
                "durationMs": 200
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)
        let result = ToolEndPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? ToolEndPlugin.Result else {
            XCTFail("Expected ToolEndPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.toolCallId, "tool-call-def")
        XCTAssertEqual(toolResult.toolName, "Write")
        XCTAssertTrue(toolResult.success)
        XCTAssertEqual(toolResult.result, "File written successfully")
        XCTAssertEqual(toolResult.durationMs, 200)
    }

    func testTransformDisplayResult() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "data": {
                "toolCallId": "tool-5",
                "success": true,
                "result": "Success content"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)
        let result = ToolEndPlugin.transform(event) as? ToolEndPlugin.Result

        XCTAssertEqual(result?.displayResult, "Success content")
    }

    func testTransformDisplayResultWithError() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "data": {
                "toolCallId": "tool-6",
                "success": false,
                "error": "Something went wrong"
            }
        }
        """.data(using: .utf8)!

        let event = try ToolEndPlugin.parse(from: json)
        let result = ToolEndPlugin.transform(event) as? ToolEndPlugin.Result

        XCTAssertEqual(result?.displayResult, "Something went wrong")
    }

    // MARK: - Parity Tests

    func testParityWithLegacyToolEndEvent() throws {
        let json = """
        {
            "type": "agent.tool_end",
            "sessionId": "parity-session",
            "data": {
                "toolCallId": "parity-tool-call",
                "toolName": "Bash",
                "success": true,
                "result": "Command output",
                "durationMs": 350
            }
        }
        """.data(using: .utf8)!

        // Parse with plugin system
        let pluginEvent = try ToolEndPlugin.parse(from: json)

        // Parse with legacy system
        let legacyEvent = try JSONDecoder().decode(ToolEndEvent.self, from: json)

        // Verify parity
        XCTAssertEqual(ToolEndPlugin.sessionId(from: pluginEvent), legacyEvent.sessionId)
        XCTAssertEqual(pluginEvent.data.toolCallId, legacyEvent.toolCallId)
        XCTAssertEqual(pluginEvent.data.toolName, legacyEvent.toolName)
        XCTAssertEqual(pluginEvent.data.success, legacyEvent.success)
        XCTAssertEqual(pluginEvent.data.durationMs, legacyEvent.durationMs)
    }
}
