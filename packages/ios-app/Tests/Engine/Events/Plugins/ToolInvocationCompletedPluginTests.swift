import XCTest
@testable import TronMobile

final class ToolInvocationCompletedPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "invocationId": "tool-invocation-abc",
                "toolName": "process_run",
                "isError": false,
                "content": "File content here",
                "duration": 150
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.type, "tool.invocation.completed")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.invocationId, "tool-invocation-abc")
        XCTAssertEqual(event.data.toolName, "process_run")
        XCTAssertFalse(event.data.isError)
        XCTAssertEqual(event.data.content, "File content here")
        XCTAssertEqual(event.data.duration, 150)
    }

    func testParseWithError() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "sessionId": "session-123",
            "data": {
                "invocationId": "tool-invocation-xyz",
                "toolName": "process_run",
                "isError": true,
                "content": "File not found",
                "duration": 42
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)

        XCTAssertTrue(event.data.isError)
        XCTAssertEqual(event.data.content, "File not found")
    }

    func testParseWithContentString() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "data": {
                "invocationId": "tool-1",
                "toolName": "process_run",
                "isError": false,
                "content": "String output",
                "duration": 5
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.content, "String output")
    }

    func testParseWithDetails() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "data": {
                "invocationId": "tool-3",
                "toolName": "process_run",
                "isError": false,
                "content": "",
                "duration": 10,
                "details": {
                    "screenshot": "base64data...",
                    "format": "png"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.details?.screenshot, "base64data...")
        XCTAssertEqual(event.data.details?.format, "png")
    }

    func testParseWithDurationField() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "data": {
                "invocationId": "tool-4",
                "toolName": "process_run",
                "isError": false,
                "content": "",
                "duration": 500
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.duration, 500)
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "sessionId": "session-456",
            "data": {
                "invocationId": "tool-invocation-def",
                "toolName": "process_run",
                "isError": false,
                "content": "File written successfully",
                "duration": 200
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)
        let result = ToolInvocationCompletedPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? ToolInvocationCompletedPlugin.Result else {
            XCTFail("Expected ToolInvocationCompletedPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.invocationId, "tool-invocation-def")
        XCTAssertEqual(toolResult.toolName, "process_run")
        XCTAssertTrue(toolResult.success)
        XCTAssertEqual(toolResult.content, "File written successfully")
        XCTAssertEqual(toolResult.duration, 200)
    }

    func testTransformCarriesCanonicalEventTimestamp() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "timestamp": "2026-05-15T04:47:31.798Z",
            "data": {
                "invocationId": "tool-timestamp",
                "toolName": "process_run",
                "isError": false,
                "content": "ok",
                "duration": 445
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)
        let result = try XCTUnwrap(ToolInvocationCompletedPlugin.transform(event) as? ToolInvocationCompletedPlugin.Result)

        XCTAssertEqual(result.timestamp, DateParser.parse("2026-05-15T04:47:31.798Z"))
    }

    func testTransformDisplayResult() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "data": {
                "invocationId": "tool-5",
                "toolName": "process_run",
                "isError": false,
                "content": "Success content",
                "duration": 12
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)
        let result = ToolInvocationCompletedPlugin.transform(event) as? ToolInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.displayResult, "Success content")
    }

    func testTransformDisplayResultWithError() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "data": {
                "invocationId": "tool-6",
                "toolName": "process_run",
                "isError": true,
                "content": "Something went wrong",
                "duration": 12
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)
        let result = ToolInvocationCompletedPlugin.transform(event) as? ToolInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.displayResult, "Something went wrong")
    }

    func testTransformPreservesCanonicalFailureEnvelope() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "data": {
                "invocationId": "tool-failure",
                "toolName": "process_run",
                "isError": true,
                "content": "Tool unavailable",
                "duration": 12,
                "details": {
                    "failure": {
                        "code": "TOOL_PRIMITIVE_NOT_FOUND",
                        "category": "tool",
                        "message": "Primitive not found",
                        "retryable": false,
                        "recoverable": false,
                        "origin": "tool",
                        "invocationId": "tool-failure"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)
        let result = try XCTUnwrap(ToolInvocationCompletedPlugin.transform(event) as? ToolInvocationCompletedPlugin.Result)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure?.code, "TOOL_PRIMITIVE_NOT_FOUND")
        XCTAssertEqual(result.failure?.category, "tool")
        XCTAssertEqual(result.failure?.recoverable, false)
    }

    func testParsesCanonicalServerEventPayloadFromToolStore() throws {
        let json = """
        {
            "type": "tool.invocation.completed",
            "sessionId": "sess_019e25c9-8f30-7ed1-ae79-1646d50e1fe7",
            "timestamp": "2026-05-14T09:24:43.940Z",
            "data": {
                "invocationId": "019e25cb-1234-7000-a000-000000000001",
                "toolName": "process_run",
                "traceId": "019e25cb-0ebe-79d1-b20c-3070e3256a15",
                "rootInvocationId": "019e25cb-6ab0-7782-8110-684e36bc6218",
                "themeColor": "#10B981",
                "presentationHints": {
                    "displayName": "List Directory",
                    "chipTitle": "List",
                    "icon": "folder",
                    "themeColor": "#10B981"
                },
                "content": "Listed runtime directory.",
                "isError": false,
                "duration": 69,
                "details": {
                    "status": "ok",
                    "output": {
                        "path": "/tmp/tron-fixtures/testspace/runtime/current",
                        "entries": []
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationCompletedPlugin.parse(from: json)
        let result = ToolInvocationCompletedPlugin.transform(event) as? ToolInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.invocationId, "019e25cb-1234-7000-a000-000000000001")
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.displayResult, "Listed runtime directory.")
        XCTAssertEqual(result?.duration, 69)
        XCTAssertEqual(result?.identity.themeColor, "#10B981")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "List Directory")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "List")
        XCTAssertEqual(result?.rawDetails?["status"]?.stringValue, "ok")
    }
}
