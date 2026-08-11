import Foundation

/// Client for agent-related engine tools.
/// Handles prompts, abort, state queries, and tool results.
final class AgentClient: EngineDomainClient, AgentRepository {

    var supportsCoordinationManagement: Bool {
        currentTransport?.engineConnection?.negotiatedCapabilities
            .contains("agent_coordination.v1") == true
    }

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

    /// Abort a single in-flight tool invocation without aborting the rest of the turn.
    /// Returns `true` when the server cancelled a registered tool, `false` when
    /// the invocation had already finished or no call matched the id.
    @discardableResult
    func abortToolInvocation(invocationId: String, idempotencyKey: EngineIdempotencyKey) async throws -> Bool {
        let (_, sessionId) = try requireTransport().requireSession()
        let params = AgentAbortInvocationParams(sessionId: sessionId, invocationId: invocationId)
        let result: AgentAbortInvocationResult = try await invokeWrite(
            "agent::abort_invocation",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
        logger.info(
            "Aborted tool invocation \(invocationId): aborted=\(result.aborted)",
            category: .chat
        )
        return result.aborted
    }

    func answerUserInput(
        invocationId: String,
        answers: [UserInputAnswer],
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        let sessionId = try await requireLiveSessionEvents()
        let params = AgentAnswerUserInputParams(
            sessionId: sessionId,
            invocationId: invocationId,
            answers: answers
        )
        let result: AgentPromptResult = try await invokeWrite(
            "agent::answer_user_input",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
        guard result.acknowledged else {
            throw EngineConnectionError.invalidResponse
        }
    }

    // MARK: - Coordination Management

    func agentRelations(
        ownerSessionId: String,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> AgentRelationsResultDTO {
        try await invokeRead(
            "agent::relations",
            AgentRelationsParams(
                ownerSessionId: ownerSessionId,
                cursor: cursor,
                limit: min(max(limit, 1), 100)
            ),
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func inspectAgent(
        ownerSessionId: String,
        agentId: String
    ) async throws -> AgentInspectDTO {
        try await invokeRead(
            "agent::inspect",
            AgentInspectParams(ownerSessionId: ownerSessionId, agentId: agentId),
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func agentAssignments(
        ownerSessionId: String,
        agentId: String,
        cursor: String? = nil,
        limit: Int = 40
    ) async throws -> AgentAssignmentsResultDTO {
        try await invokeRead(
            "agent::assignments",
            AgentAssignmentsParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                cursor: cursor,
                limit: min(max(limit, 1), 100)
            ),
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func agentMessages(
        ownerSessionId: String,
        agentId: String,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> AgentMessagesResultDTO {
        try await invokeRead(
            "agent::messages",
            AgentMessagesParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                cursor: cursor,
                limit: min(max(limit, 1), 100)
            ),
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func agentMessageDetail(
        ownerSessionId: String,
        agentId: String,
        messageId: String
    ) async throws -> AgentMessageDetailDTO {
        try await invokeRead(
            "agent::message_detail",
            AgentMessageDetailParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                messageId: messageId
            ),
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func agentResult(
        ownerSessionId: String,
        agentId: String,
        resultId: String,
        pointer: String = "",
        offset: UInt64 = 0,
        limit: UInt8 = 20
    ) async throws -> AgentResultChunkDTO {
        try await invokeRead(
            "agent::result_read",
            AgentResultReadParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                resultId: resultId,
                pointer: pointer,
                offset: offset,
                limit: min(max(limit, 1), 20)
            ),
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func sendOperatorMessage(
        ownerSessionId: String,
        agentId: String,
        content: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try await invokeWrite(
            "agent::operator_message",
            AgentOperatorMessageParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                clientMutationId: idempotencyKey.rawValue,
                content: content
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func manageAgent(
        ownerSessionId: String,
        agentId: String,
        action: String,
        assignmentId: String? = nil,
        cascade: Bool? = nil,
        configuration: AnyCodable? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try await invokeWrite(
            "agent::manage",
            AgentManageParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                clientMutationId: idempotencyKey.rawValue,
                action: action,
                assignmentId: assignmentId,
                cascade: cascade,
                configuration: configuration
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func retryAgentAssignment(
        ownerSessionId: String,
        agentId: String,
        assignmentId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try await invokeWrite(
            "agent::retry",
            AgentRetryParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                clientMutationId: idempotencyKey.rawValue,
                assignmentId: assignmentId
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(ownerSessionId)
        )
    }

    func promoteAgent(
        ownerSessionId: String,
        agentId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try await invokeWrite(
            "agent::promote",
            AgentPromoteParams(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                clientMutationId: idempotencyKey.rawValue
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(ownerSessionId)
        )
    }

}
