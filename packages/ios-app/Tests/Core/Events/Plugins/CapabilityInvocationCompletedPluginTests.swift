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
                "success": true,
                "output": "File content here",
                "duration": 150
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.type, "capability.invocation.completed")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.invocationId, "capability-invocation-abc")
        XCTAssertEqual(event.data.modelPrimitiveName, "execute")
        XCTAssertTrue(event.data.success)
        XCTAssertEqual(event.data.output, "File content here")
        XCTAssertEqual(event.data.duration, 150)
    }

    func testParseWithError() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "sessionId": "session-123",
            "data": {
                "invocationId": "capability-invocation-xyz",
                "success": false,
                "error": "File not found"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertFalse(event.data.success)
        XCTAssertEqual(event.data.error, "File not found")
    }

    func testParseWithOutputAsString() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-1",
                "success": true,
                "output": "String output"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.output, "String output")
    }

    func testParseWithOutputAsContentBlockArray() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-2",
                "success": true,
                "output": [
                    {"type": "text", "text": "First part"},
                    {"type": "text", "text": " Second part"}
                ]
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)

        XCTAssertEqual(event.data.output, "First part Second part")
    }

    func testParseWithDetails() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-3",
                "success": true,
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
                "success": true,
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
                "success": true,
                "output": "File written successfully",
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
        XCTAssertEqual(capabilityResult.output, "File written successfully")
        XCTAssertEqual(capabilityResult.duration, 200)
    }

    func testTransformDisplayResult() throws {
        let json = """
        {
            "type": "capability.invocation.completed",
            "data": {
                "invocationId": "capability-5",
                "success": true,
                "output": "Success content"
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
                "success": false,
                "error": "Something went wrong"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationCompletedPlugin.parse(from: json)
        let result = CapabilityInvocationCompletedPlugin.transform(event) as? CapabilityInvocationCompletedPlugin.Result

        XCTAssertEqual(result?.displayResult, "Something went wrong")
    }
}
