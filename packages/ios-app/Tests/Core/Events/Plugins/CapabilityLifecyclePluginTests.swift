import XCTest
@testable import TronMobile

final class CapabilityLifecyclePluginTests: XCTestCase {

    func testPauseRequestedDecodesCapabilityIdentityAndPromptPayload() throws {
        let json = """
        {
            "type": "capability.pause.requested",
            "sessionId": "session-123",
            "timestamp": "2026-05-14T10:00:00Z",
            "data": {
                "pauseId": "pause-1",
                "invocationId": "inv-1",
                "kind": "user_input",
                "status": "pending",
                "promptPayload": {
                    "questions": [{ "id": "q1", "question": "Proceed?", "options": [] }]
                },
                "answerAuthority": "user_client",
                "modelPrimitiveName": "execute",
                "operationName": "ask_user",
                "presentationHints": {
                    "displayName": "Ask User",
                    "chipTitle": "Ask",
                    "icon": "question",
                    "themeColor": "#F59E0B"
                }
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityPauseRequestedPlugin.parse(from: json)
        let result = CapabilityPauseRequestedPlugin.transform(event) as? CapabilityPauseRequestedPlugin.Result

        XCTAssertEqual(result?.pauseId, "pause-1")
        XCTAssertEqual(result?.kind, "user_input")
        XCTAssertEqual(result?.identity.operationName, "ask_user")
        XCTAssertEqual(result?.identity.presentationHints?["displayName"]?.stringValue, "Ask User")
        XCTAssertEqual(result?.identity.presentationHints?["chipTitle"]?.stringValue, "Ask")
        XCTAssertNotNil(result?.promptPayload?["questions"])
    }

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
