import XCTest
@testable import TronMobile

final class CapabilityInvocationGeneratingPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "capability.invocation.generating",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "modelToolName": "Write",
                "invocationId": "tc1"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)

        XCTAssertEqual(event.type, "capability.invocation.generating")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.modelToolName, "Write")
        XCTAssertEqual(event.data.invocationId, "tc1")
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "capability.invocation.generating",
            "sessionId": "session-456",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "modelToolName": "Bash",
                "invocationId": "tc2"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)
        let result = CapabilityInvocationGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? CapabilityInvocationGeneratingPlugin.Result else {
            XCTFail("Expected CapabilityInvocationGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.modelToolName, "Bash")
        XCTAssertEqual(toolResult.invocationId, "tc2")
    }

    func testTransformMinimalPayload() throws {
        let json = """
        {
            "type": "capability.invocation.generating",
            "data": {
                "modelToolName": "Read",
                "invocationId": "tc3"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)
        let result = CapabilityInvocationGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let toolResult = result as? CapabilityInvocationGeneratingPlugin.Result else {
            XCTFail("Expected CapabilityInvocationGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(toolResult.modelToolName, "Read")
        XCTAssertEqual(toolResult.invocationId, "tc3")
    }
}
