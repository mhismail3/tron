import XCTest
@testable import TronMobile

final class CapabilityInvocationOutputPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "capability.invocation.output",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "invocationId": "capability-invocation-abc",
                "output": "partial stdout chunk"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationOutputPlugin.parse(from: json)

        XCTAssertEqual(event.type, "capability.invocation.output")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.invocationId, "capability-invocation-abc")
        XCTAssertEqual(event.data.output, "partial stdout chunk")
    }

    func testParseWithoutSessionId() throws {
        let json = """
        {
            "type": "capability.invocation.output",
            "data": {
                "invocationId": "tool-1",
                "output": "chunk"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationOutputPlugin.parse(from: json)

        XCTAssertNil(event.sessionId)
        XCTAssertEqual(event.data.invocationId, "tool-1")
        XCTAssertEqual(event.data.output, "chunk")
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "capability.invocation.output",
            "sessionId": "session-456",
            "data": {
                "invocationId": "capability-invocation-def",
                "output": "streaming output text"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationOutputPlugin.parse(from: json)
        let result = CapabilityInvocationOutputPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let outputResult = result as? CapabilityInvocationOutputPlugin.Result else {
            XCTFail("Expected CapabilityInvocationOutputPlugin.Result")
            return
        }

        XCTAssertEqual(outputResult.invocationId, "capability-invocation-def")
        XCTAssertEqual(outputResult.output, "streaming output text")
    }
}
