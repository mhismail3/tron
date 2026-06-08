import XCTest
@testable import TronMobile

final class CapabilityInvocationCompletedPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "invocationId": "capability-invocation-abc",
                "modelPrimitiveName": "execute",
                "isError": false,
                "content": "File content here",
                "duration": 150
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.type, "capability.invocation.completed")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.invocationId, "capability-invocation-abc")
        XCTAssertEqual(event.data.modelPrimitiveName, "execute")
        XCTAssertFalse(event.data.isError)
        XCTAssertEqual(event.data.content, "File content here")
        XCTAssertEqual(event.data.duration, 150)
    }

    func testParseWithError() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "sessionId": "session-123",
            "data": {
                "invocationId": "capability-invocation-xyz",
                "modelPrimitiveName": "execute",
                "isError": true,
                "content": "File not found",
                "duration": 42
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertTrue(event.data.isError)
        XCTAssertEqual(event.data.content, "File not found")
    }

    func testParseWithContentString() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-1",
                "modelPrimitiveName": "execute",
                "isError": false,
                "content": "String output",
                "duration": 5
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.content, "String output")
    }

    func testParseWithDetails() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-3",
                "modelPrimitiveName": "execute",
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

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.details?.screenshot, "base64data...")
        XCTAssertEqual(event.data.details?.format, "png")
    }

    func testParseWithDurationField() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-4",
                "modelPrimitiveName": "execute",
                "isError": false,
                "content": "",
                "duration": 500
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.duration, 500)
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "sessionId": "session-456",
            "data": {
                "invocationId": "capability-invocation-def",
                "modelPrimitiveName": "execute",
                "isError": false,
                "content": "File written successfully",
                "duration": 200
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)
        let result = CapabilityInvocationCompletedPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let capabilityResult = result as? CapabilityInvocationCompletedPlugin.Result else {
            XCTFail("Expected CapabilityInvocationCompletedPlugin.Result")
            return
        }

        XCTAssertEqual(capabilityResult.invocationId, "capability-invocation-def")
        XCTAssertEqual(capabilityResult.modelPrimitiveName, "execute")
        XCTAssertTrue(capabilityResult.success)
        XCTAssertEqual(capabilityResult.content, "File written successfully")
        XCTAssertEqual(capabilityResult.duration, 200)
    }

    func testTransformCarriesCanonicalEventTimestamp() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "timestamp": "2026-05-15T04:47:31.798Z",
            "data": {
                "invocationId": "capability-timestamp",
                "modelPrimitiveName": "execute",
                "isError": false,
                "content": "ok",
                "duration": 445
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)
        let result = try XCTUnwrap(CapabilityInvocationCompletedPlugin.transform(event) as? CapabilityInvocationCompletedPlugin.Result)

        XCTAssertEqual(result.timestamp, DateParser.parse("2026-05-15T04:47:31.798Z"))
    }

    func testTransformDisplayResult() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-5",
                "modelPrimitiveName": "execute",
                "isError": false,
                "content": "Success content",
                "duration": 12
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)
        let result = CapabilityInvocationCompletedPlugin.transform(event) as? CapabilityInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.displayResult, "Success content")
    }

    func testTransformDisplayResultWithError() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-6",
                "modelPrimitiveName": "execute",
                "isError": true,
                "content": "Something went wrong",
                "duration": 12
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)
        let result = CapabilityInvocationCompletedPlugin.transform(event) as? CapabilityInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.displayResult, "Something went wrong")
    }

    func testParsesCanonicalServerEventPayloadFromCapabilityStore() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "sessionId": "sess_019e25c9-8f30-7ed1-ae79-1646d50e1fe7",
            "timestamp": "2026-05-14T09:24:43.940Z",
            "data": {
                "invocationId": "019e25cb-1234-7000-a000-000000000001",
                "modelPrimitiveName": "execute",
                "operationName": "file_list",
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

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)
        let result = CapabilityInvocationCompletedPlugin.transform(event) as? CapabilityInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.invocationId, "019e25cb-1234-7000-a000-000000000001")
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.displayResult, "Listed runtime directory.")
        XCTAssertEqual(result?.duration, 69)
        XCTAssertEqual(result?.identity.operationName, "file_list")
        XCTAssertEqual(result?.identity.themeColor, "#10B981")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "List Directory")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "List")
        XCTAssertEqual(result?.rawDetails?["status"]?.stringValue, "ok")
    }
}
