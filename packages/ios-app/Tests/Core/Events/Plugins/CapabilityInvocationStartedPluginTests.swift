import XCTest
@testable import TronMobile

final class CapabilityInvocationStartedPluginTests: XCTestCase {

    func testTransformCarriesServerOwnedPresentationHints() throws {
        let json = """
        {
            "type": "capability.invocation.started",
            "sessionId": "session-123",
            "timestamp": "2026-05-21T10:00:00Z",
            "data": {
                "modelPrimitiveName": "execute",
                "invocationId": "inv-1",
                "arguments": { "command": "pwd" },
                "contractId": "process::run",
                "presentationHints": {
                    "displayName": "Shell Command",
                    "chipTitle": "Shell",
                    "icon": "terminal",
                    "themeColor": "#38BDF8"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityInvocationStartedPlugin.parse(from: json)
        let result = CapabilityInvocationStartedPlugin.transform(event) as? CapabilityInvocationStartedPlugin.Result

        XCTAssertEqual(result?.invocationId, "inv-1")
        XCTAssertEqual(result?.identity.contractId, "process::run")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "Shell Command")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "Shell")
        XCTAssertEqual(result?.identity.presentationHints?["icon"]?.stringValue, "terminal")
        XCTAssertEqual(result?.identity.presentationHints?["themeColor"]?.stringValue, "#38BDF8")
    }
}
