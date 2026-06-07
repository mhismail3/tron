import Foundation

/// Client for agent-related engine capabilities.
/// Handles prompts, abort, state queries, and capability results.
final class AgentClient: EngineDomainClient {

    // MARK: - Agent Methods

    private func requireLiveSessionEvents() async throws -> String {
        let transport = try requireTransport()
        let (_, sessionId) = try transport.requireSession()
        try await transport.ensureSessionEventSubscription(sessionId: sessionId, workspaceId: nil)
        return sessionId
    }

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        let sessionId = try await requireLiveSessionEvents()

        let params = AgentPromptParams(
            sessionId: sessionId,
            prompt: prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel
        )

        let result: AgentPromptResult = try await invokeWrite(
            "agent::prompt",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        if !result.acknowledged {
            logger.warning("Prompt not acknowledged by server", category: .chat)
        }
    }

    // MARK: - Prompt Queue Methods

    /// Queue a prompt for later delivery when the agent becomes ready.
    /// Server persists a `message.queued` event and publishes it through engine streams.
    func queuePrompt(_ text: String, idempotencyKey: EngineIdempotencyKey) async throws -> PendingQueueItem {
        let sessionId = try await requireLiveSessionEvents()
        let params = QueuePromptParams(sessionId: sessionId, prompt: text)
        return try await invokeWrite(
            "agent::queue_prompt",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Cancel a specific queued prompt by its queue ID.
    func dequeuePrompt(_ queueId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        let sessionId = try await requireLiveSessionEvents()
        let params = DequeuePromptParams(sessionId: sessionId, queueId: queueId)
        let _: DequeueResult = try await invokeWrite(
            "agent::dequeue_prompt",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Clear all queued prompts for the current session.
    func clearQueue(idempotencyKey: EngineIdempotencyKey) async throws {
        let sessionId = try await requireLiveSessionEvents()
        let params = ClearQueueParams(sessionId: sessionId)
        let _: ClearQueueResult = try await invokeWrite(
            "agent::clear_queue",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    func abort(idempotencyKey: EngineIdempotencyKey) async throws {
        guard let (_, sessionId) = try? requireTransport().requireSession() else { return }

        let params = AgentAbortParams(sessionId: sessionId)
        let _: EmptyParams = try await invokeWrite(
            "agent::abort",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
        logger.info("Aborted agent", category: .chat)
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
