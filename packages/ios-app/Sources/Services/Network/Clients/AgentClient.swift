import Foundation

/// Client for agent-related engine capabilities.
/// Handles prompts, abort, state queries, and tool results.
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

    // MARK: - Session-Scoped Skill Methods

    func activateSkill(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws -> SkillActivateResult {
        let (_, sessionId) = try requireTransport().requireSession()
        let params = SkillActivateParams(sessionId: sessionId, skillName: skillName)
        return try await invokeWrite(
            "skills::activate",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    func deactivateSkill(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws -> SkillDeactivateResult {
        let (_, sessionId) = try requireTransport().requireSession()
        let params = SkillDeactivateParams(sessionId: sessionId, skillName: skillName)
        return try await invokeWrite(
            "skills::deactivate",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    func activeSkills() async throws -> SkillActiveResult {
        let (_, sessionId) = try requireTransport().requireSession()
        let params = SkillActiveParams(sessionId: sessionId)
        return try await invokeRead("skills::active", params)
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

    // MARK: - Subagent Result Delivery

    /// Deliver pending subagent results as a server-constructed prompt.
    /// The server formats the results and either spawns a prompt run or queues if busy.
    func deliverSubagentResults(idempotencyKey: EngineIdempotencyKey) async throws -> DeliverSubagentResultsResponse {
        let sessionId = try await requireLiveSessionEvents()
        let params = DeliverSubagentResultsParams(sessionId: sessionId)
        return try await invokeWrite(
            "agent::deliver_subagent_results",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    // MARK: - Confirmation/Answer Submission

    /// Submit a confirmation decision for a GetConfirmation tool call.
    /// Server constructs the prompt and spawns a prompt run (or queues if busy).
    func submitConfirmation(
        action: String,
        decision: String,
        note: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SubmitConfirmationResponse {
        let sessionId = try await requireLiveSessionEvents()
        let params = SubmitConfirmationParams(
            sessionId: sessionId,
            action: action,
            decision: decision,
            note: note
        )
        return try await invokeWrite(
            "agent::submit_confirmation",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Submit answers for an AskUserQuestion tool call.
    /// Server constructs the prompt and spawns a prompt run (or queues if busy).
    func submitAnswers(
        questions: [AnswerSubmission],
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SubmitAnswersResponse {
        let sessionId = try await requireLiveSessionEvents()
        let params = SubmitAnswersParams(sessionId: sessionId, questions: questions)
        return try await invokeWrite(
            "agent::submit_answers",
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

    /// Abort a single in-flight tool call without aborting the rest of the turn.
    /// Returns `true` when the server cancelled a registered tool, `false` when
    /// the tool had already finished or no call matched the id.
    @discardableResult
    func abortTool(toolCallId: String, idempotencyKey: EngineIdempotencyKey) async throws -> Bool {
        let (_, sessionId) = try requireTransport().requireSession()
        let params = AgentAbortToolParams(sessionId: sessionId, toolCallId: toolCallId)
        let result: AgentAbortToolResult = try await invokeWrite(
            "agent::abort_tool",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
        logger.info(
            "Aborted tool call \(toolCallId): aborted=\(result.aborted)",
            category: .chat
        )
        return result.aborted
    }

    // MARK: - Tool Result Methods

    /// Send a tool result for interactive tools like AskUserQuestion.
    /// This unblocks the agent which is waiting for user input.
    func sendToolResult(
        sessionId: String,
        toolCallId: String,
        result: AskUserQuestionResult,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        try await requireTransport().ensureSessionEventSubscription(sessionId: sessionId, workspaceId: nil)
        let params = ToolResultParams(sessionId: sessionId, toolCallId: toolCallId, result: result)
        logger.info("[TOOL_RESULT] Sending tool result: sessionId=\(sessionId), toolCallId=\(toolCallId)", category: .session)

        let response: ToolResultResponse = try await invokeWrite(
            "tool::result",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        logger.info("[TOOL_RESULT] Tool result sent successfully: success=\(response.success)", category: .session)
    }
}
