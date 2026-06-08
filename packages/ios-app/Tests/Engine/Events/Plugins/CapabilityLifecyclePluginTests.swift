import XCTest
@testable import TronMobile

final class CapabilityLifecyclePluginTests: XCTestCase {

    func testRunStatusDecodesChildInvocationsAndIdentity() throws {
        let json = """
        {
            "type": "capability.run.status",
            "sessionId": "session-123",
            "timestamp": "2026-05-14T10:00:00Z",
            "data": {
                "runId": "run-1",
                "invocationId": "inv-1",
                "status": "running",
                "streamTopic": "agent.runtime",
                "childInvocations": ["child-1"],
                "details": { "task": "inspect" },
                "modelPrimitiveName": "execute",
                "operationName": "state_list",
                "presentationHints": {
                    "displayName": "List Directory",
                    "chipTitle": "List",
                    "icon": "folder",
                    "themeColor": "#10B981"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityRunStatusPlugin.parse(from: json)
        let result = CapabilityRunStatusPlugin.transform(event) as? CapabilityRunStatusPlugin.Result

        XCTAssertEqual(result?.runId, "run-1")
        XCTAssertEqual(result?.status, "running")
        XCTAssertEqual(result?.childInvocations, ["child-1"])
        XCTAssertEqual(result?.identity.operationName, "state_list")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "List Directory")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "List")
    }
}
