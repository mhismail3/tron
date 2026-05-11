import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("ApprovalClient Tests")
struct ApprovalClientTests {

    @Test("approval resolve invokes canonical approval worker with user authority scope")
    func approvalResolveUsesCanonicalEngineFunction() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        transport.currentSessionId = "session-1"
        let client = ApprovalClient(transport: transport)

        transport.writeHandler = { functionId, payload, _, options in
            #expect(functionId.rawValue == "approval::resolve")
            #expect(options.context?.sessionId == "session-1")
            #expect(options.context?.authorityScopes.contains("approval.resolve") == true)
            let params = payload as? EngineApprovalResolveParams
            #expect(params?.approvalId == "approval-1")
            #expect(params?.decision == "approve")
            #expect(params?.sessionId == "session-1")
            return EngineApprovalResolveResult(
                approval: EngineApprovalRecordDTO(
                    approvalId: "approval-1",
                    functionId: "sandbox::spawn_worker",
                    payload: nil,
                    actorId: nil,
                    actorKind: nil,
                    authorityScopes: nil,
                    traceId: "trace-1",
                    parentInvocationId: nil,
                    sessionId: "session-1",
                    workspaceId: nil,
                    idempotencyKey: "spawn-1",
                    status: .executed,
                    decisionActorId: "engine-user",
                    decidedAt: "2026-05-10T00:00:00Z",
                    createdAt: nil,
                    updatedAt: nil
                ),
                child: nil
            )
        }

        let result = try await client.resolve(
            approvalId: "approval-1",
            decision: .approve,
            idempotencyKey: "ios:approval.resolve:approval-1:approve"
        )

        #expect(result.approval.status == .executed)
        #expect(transport.lastWriteFunctionId?.rawValue == "approval::resolve")
        #expect(transport.lastWriteIdempotencyKey?.rawValue == "ios:approval.resolve:approval-1:approve")
    }
}
