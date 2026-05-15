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
                "modelPrimitiveName": "execute",
                "invocationId": "tc1"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)

        XCTAssertEqual(event.type, "capability.invocation.generating")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data.modelPrimitiveName, "execute")
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
                "modelPrimitiveName": "execute",
                "invocationId": "tc2"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)
        let result = CapabilityInvocationGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let capabilityResult = result as? CapabilityInvocationGeneratingPlugin.Result else {
            XCTFail("Expected CapabilityInvocationGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(capabilityResult.modelPrimitiveName, "execute")
        XCTAssertEqual(capabilityResult.invocationId, "tc2")
        XCTAssertEqual(capabilityResult.timestamp, DateParser.parse("2025-01-26T10:00:00Z"))
    }

    func testTransformMinimalPayload() throws {
        let json = """
        {
            "type": "capability.invocation.generating",
            "data": {
                "modelPrimitiveName": "execute",
                "invocationId": "tc3"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)
        let result = CapabilityInvocationGeneratingPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let capabilityResult = result as? CapabilityInvocationGeneratingPlugin.Result else {
            XCTFail("Expected CapabilityInvocationGeneratingPlugin.Result")
            return
        }

        XCTAssertEqual(capabilityResult.modelPrimitiveName, "execute")
        XCTAssertEqual(capabilityResult.invocationId, "tc3")
    }
}
