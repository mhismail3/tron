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
                "contractId": "filesystem::list_dir",
                "implementationId": "first_party.filesystem.v1.list_dir",
                "functionId": "filesystem::list_dir",
                "pluginId": "first_party.filesystem",
                "workerId": "filesystem",
                "schemaDigest": "a8fe337ce28191708a15186227c6614c65da77c8771a9c6a8666bd097e462139",
                "catalogRevision": 303,
                "trustTier": "first_party_signed",
                "riskLevel": "low",
                "effectClass": "pure_read",
                "traceId": "019e25cb-0ebe-79d1-b20c-3070e3256a15",
                "rootInvocationId": "019e25cb-6ab0-7782-8110-684e36bc6218",
                "bindingDecisionId": "binding_decision_019e25cb",
                "content": "Listed session worktree.",
                "isError": false,
                "duration": 69,
                "details": {
                    "status": "ok",
                    "output": {
                        "path": "/Users/moose/Downloads/projects/testspace/.worktrees/session/sess_019e25c9-8f30-7ed1-ae79-1646d50e1fe7",
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
        XCTAssertEqual(result?.displayResult, "Listed session worktree.")
        XCTAssertEqual(result?.duration, 69)
        XCTAssertEqual(result?.identity.contractId, "filesystem::list_dir")
        XCTAssertEqual(result?.rawDetails?["status"]?.stringValue, "ok")
    }
}
