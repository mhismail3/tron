import XCTest
@testable import TronMobile

final class EngineApprovalTimelineTests: XCTestCase {
    func testApprovalInsertedBetweenExecuteAndResultByCreatedAt() {
        let execute = ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(CapabilityInvocationData(
                id: "execute-call",
                status: .success,
                arguments: "{}",
                identity: testCapabilityIdentity(modelPrimitiveName: "execute", contractId: "process::run")
            )),
            timestamp: DateParser.parseOrNow("2026-05-21T07:47:16.436Z")
        )
        let result = ChatMessage(
            role: .assistant,
            content: .text("final answer"),
            timestamp: DateParser.parseOrNow("2026-05-21T07:47:35.670Z")
        )
        var messages = [execute, result]
        let approval = EngineApprovalRecordDTO(
            approvalId: "approval-1",
            functionId: "process::run",
            payload: nil,
            actorId: nil,
            actorKind: nil,
            authorityGrantId: "grant-1",
            authorityScopes: nil,
            traceId: nil,
            parentInvocationId: "execute-wrapper",
            sessionId: "session-1",
            workspaceId: nil,
            idempotencyKey: "write-1",
            targetMetadata: nil,
            status: .executed,
            decisionActorId: "engine-user",
            decidedAt: "2026-05-21T07:47:29.162Z",
            createdAt: "2026-05-21T07:47:16.542Z",
            updatedAt: "2026-05-21T07:47:29.195Z"
        )
        let approvalMessage = ChatMessage(
            role: .assistant,
            content: .engineApproval(EngineApprovalData(
                invocationId: "engine-approval:approval-1",
                params: EngineApprovalParams(
                    action: "Run command",
                    reason: "Requires approval",
                    riskLevel: .high
                ),
                status: .approved,
                engineApprovalId: "approval-1",
                engineFunctionId: "process::run"
            )),
            timestamp: EngineApprovalTimeline.timestamp(for: approval)
        )

        EngineApprovalTimeline.insert(approvalMessage, into: &messages)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].id, execute.id)
        if case .engineApproval(let data) = messages[1].content {
            XCTAssertEqual(data.engineApprovalId, "approval-1")
        } else {
            XCTFail("approval should be inserted between execute chip and final result")
        }
        XCTAssertEqual(messages[2].id, result.id)
    }
}
