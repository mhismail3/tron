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
                "contractId": "agent::ask_user",
                "implementationId": "first_party.agent.v1.ask_user",
                "functionId": "agent::ask_user",
                "modelPrimitiveName": "execute"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityPauseRequestedPlugin.parse(from: json)
        let result = CapabilityPauseRequestedPlugin.transform(event) as? CapabilityPauseRequestedPlugin.Result

        XCTAssertEqual(result?.pauseId, "pause-1")
        XCTAssertEqual(result?.kind, "user_input")
        XCTAssertEqual(result?.identity.contractId, "agent::ask_user")
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
                "contractId": "agent::spawn_subagent",
                "implementationId": "first_party.agent.v1.spawn_subagent",
                "functionId": "agent::spawn_subagent",
                "modelPrimitiveName": "execute"
            }
        }
        """.data(using: .utf8)!

        let event = try CapabilityRunStatusPlugin.parse(from: json)
        let result = CapabilityRunStatusPlugin.transform(event) as? CapabilityRunStatusPlugin.Result

        XCTAssertEqual(result?.runId, "run-1")
        XCTAssertEqual(result?.status, "running")
        XCTAssertEqual(result?.childInvocations, ["child-1"])
        XCTAssertEqual(result?.identity.contractId, "agent::spawn_subagent")
    }
}
