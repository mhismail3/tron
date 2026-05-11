import Foundation

/// Client for the engine approval primitive worker.
///
/// Approval decisions are ordinary canonical engine invocations:
/// `/engine.invoke -> approval::resolve -> approval worker -> ledger/streams`.
final class ApprovalClient: EngineDomainClient {

    func resolve(
        approvalId: String,
        decision: EngineApprovalDecision,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> EngineApprovalResolveResult {
        let transport = try requireTransport()
        _ = try transport.requireConnection()

        let scopedSessionId = sessionId ?? transport.currentSessionId
        let params = EngineApprovalResolveParams(
            approvalId: approvalId,
            decision: decision.rawValue,
            sessionId: scopedSessionId,
            workspaceId: workspaceId
        )
        let context = EngineInvocationContext(
            sessionId: scopedSessionId,
            workspaceId: workspaceId,
            authorityScopes: ["approval.resolve"]
        )

        logger.info(
            "Resolving engine approval via approval::resolve approvalId=\(approvalId) decision=\(decision.rawValue) session=\(scopedSessionId ?? "nil")",
            category: .engine
        )

        return try await invokeWrite(
            "approval::resolve",
            params,
            idempotencyKey: idempotencyKey,
            context: context
        )
    }
}
