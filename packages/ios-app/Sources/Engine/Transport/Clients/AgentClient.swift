import Foundation

/// Client for agent-related engine capabilities.
/// Handles prompts, abort, state queries, and capability results.
final class AgentClient: EngineDomainClient, AgentRepository {

    // MARK: - Agent Methods

    private func requireLiveSessionEvents() async throws -> String {
        let transport = try requireTransport()
        let (_, sessionId) = try transport.requireSession()
        try await transport.ensureSessionEventSubscription(sessionId: sessionId, workspaceId: nil)
        return sessionId
    }

    func sendPrompt(
        _ prompt: String,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        let sessionId = try await requireLiveSessionEvents()

        let params = AgentPromptParams(
            sessionId: sessionId,
            prompt: prompt,
            attachments: attachments,
            reasoningLevel: reasoningLevel
        )

        let result: AgentPromptResult = try await invokeWrite(
            "agent::prompt",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        guard result.acknowledged else {
            logger.warning("Prompt not acknowledged by server", category: .chat)
            throw EngineConnectionError.invalidResponse
        }
    }

    @discardableResult
    func abort(idempotencyKey: EngineIdempotencyKey) async throws -> Bool {
        guard let (_, sessionId) = try? requireTransport().requireSession() else { return false }

        let params = AgentAbortParams(sessionId: sessionId)
        let result: AgentAbortResult = try await invokeWrite(
            "agent::abort",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
        logger.info("Requested agent abort: matched=\(result.aborted)", category: .chat)
        return result.aborted
    }

    /// Abort a single in-flight capability invocation without aborting the rest of the turn.
    /// Returns `true` when the server cancelled a registered capability, `false` when
    /// the invocation had already finished or no call matched the id.
    @discardableResult
    func abortCapabilityInvocation(invocationId: String, idempotencyKey: EngineIdempotencyKey) async throws -> Bool {
        let (_, sessionId) = try requireTransport().requireSession()
        let params = AgentAbortInvocationParams(sessionId: sessionId, invocationId: invocationId)
        let result: AgentAbortInvocationResult = try await invokeWrite(
            "agent::abort_invocation",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
        logger.info(
            "Aborted capability invocation \(invocationId): aborted=\(result.aborted)",
            category: .chat
        )
        return result.aborted
    }

}
