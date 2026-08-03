import XCTest
@testable import TronMobile

final class ToolInvocationStartedPluginTests: XCTestCase {

    func testTransformCarriesServerOwnedPresentationHints() throws {
        let json = """
        {
            "type": "tool.invocation.started",
            "sessionId": "session-123",
            "timestamp": "2026-05-21T10:00:00Z",
            "data": {
                "toolName": "process_run",
                "invocationId": "inv-1",
                "arguments": { "command": "pwd" },
                "presentationHints": {
                    "displayName": "Shell Command",
                    "chipTitle": "Shell",
                    "icon": "terminal",
                    "themeColor": "#38BDF8"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try ToolInvocationStartedPlugin.parse(from: json)
        let result = ToolInvocationStartedPlugin.transform(event) as? ToolInvocationStartedPlugin.Result

        XCTAssertEqual(result?.invocationId, "inv-1")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "Shell Command")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "Shell")
        XCTAssertEqual(result?.identity.presentationHints?["icon"]?.stringValue, "terminal")
        XCTAssertEqual(result?.identity.presentationHints?["themeColor"]?.stringValue, "#38BDF8")
    }
}
