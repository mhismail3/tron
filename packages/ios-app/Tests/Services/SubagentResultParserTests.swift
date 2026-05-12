import Testing
@testable import TronMobile

@Suite("Subagent Result Parser Tests")
struct SubagentResultParserTests {
    @Test("Failed spawn without session id never uses tool call id as child session")
    func failedSpawnWithoutSessionIdHasNoHistoryTarget() {
        let tool = ToolUseData(
            toolName: "SpawnSubagent",
            toolCallId: "call_failed_spawn",
            arguments: #"{"task":"leaf"}"#,
            status: .error,
            result: "Failed to spawn subagent",
            details: [
                "success": AnyCodable(false),
            ]
        )

        let parsed = ToolResultParser.parseSpawnSubagent(from: tool)

        #expect(parsed != nil)
        #expect(parsed?.status == .failed)
        #expect(parsed?.subagentSessionId == "")
        #expect(parsed?.hasSubagentSession == false)
    }

    @Test("Successful spawn keeps server-owned child session id")
    func successfulSpawnUsesStructuredSessionId() {
        let tool = ToolUseData(
            toolName: "SpawnSubagent",
            toolCallId: "call_spawn",
            arguments: #"{"task":"leaf"}"#,
            status: .success,
            result: "done",
            details: [
                "sessionId": AnyCodable("sess_child"),
                "success": AnyCodable(true),
                "totalTurns": AnyCodable(1),
            ]
        )

        let parsed = ToolResultParser.parseSpawnSubagent(from: tool)

        #expect(parsed?.subagentSessionId == "sess_child")
        #expect(parsed?.hasSubagentSession == true)
        #expect(parsed?.currentTurn == 1)
    }
}
