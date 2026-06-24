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

    func testTransformCarriesServerOwnedPresentationHints() throws {
        let json = """
        {
            "type": "capability.invocation.generating",
            "data": {
                "modelPrimitiveName": "execute",
                "invocationId": "tc4",
                "operationName": "process_run",
                "presentationHints": {
                    "displayName": "Shell Command",
                    "chipTitle": "Shell",
                    "icon": "terminal",
                    "themeColor": "#38BDF8"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationGeneratingPlugin.parse(from: json)
        let result = CapabilityInvocationGeneratingPlugin.transform(event) as? CapabilityInvocationGeneratingPlugin.Result

        XCTAssertEqual(result?.identity.operationName, "process_run")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "Shell Command")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "Shell")
        XCTAssertEqual(result?.identity.presentationHints?["icon"]?.stringValue, "terminal")
        XCTAssertEqual(result?.identity.presentationHints?["themeColor"]?.stringValue, "#38BDF8")
    }
}
