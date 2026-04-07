import Foundation

/// Client for agent-related RPC methods.
/// Handles prompts, abort, state queries, and tool results.
final class AgentClient: RPCDomainClient {

    // MARK: - Agent Methods

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil
    ) async throws {
        let (ws, sessionId) = try requireTransport().requireSession()

        let params = AgentPromptParams(
            sessionId: sessionId,
            prompt: prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel
        )

        let result: AgentPromptResult = try await ws.send(
            method: "agent.prompt",
            params: params
        )

        if !result.acknowledged {
            logger.warning("Prompt not acknowledged by server", category: .chat)
        }
    }

    // MARK: - Session-Scoped Skill Methods

    func activateSkill(_ skillName: String) async throws -> SkillActivateResult {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = SkillActivateParams(sessionId: sessionId, skillName: skillName)
        return try await ws.send(method: "skill.activate", params: params)
    }

    func deactivateSkill(_ skillName: String) async throws -> SkillDeactivateResult {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = SkillDeactivateParams(sessionId: sessionId, skillName: skillName)
        return try await ws.send(method: "skill.deactivate", params: params)
    }

    func castSpell(_ spellName: String) async throws -> SpellCastResult {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = SpellCastParams(sessionId: sessionId, spellName: spellName)
        return try await ws.send(method: "spell.cast", params: params)
    }

    func activeSkills() async throws -> SkillActiveResult {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = SkillActiveParams(sessionId: sessionId)
        return try await ws.send(method: "skill.active", params: params)
    }

    // MARK: - Prompt Queue Methods

    /// Queue a prompt for later delivery when the agent becomes ready.
    /// Server persists a `message.queued` event and broadcasts it via WebSocket.
    func queuePrompt(_ text: String) async throws -> PendingQueueItem {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = QueuePromptParams(sessionId: sessionId, prompt: text)
        return try await ws.send(method: "agent.queuePrompt", params: params)
    }

    /// Cancel a specific queued prompt by its queue ID.
    func dequeuePrompt(_ queueId: String) async throws {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = DequeuePromptParams(sessionId: sessionId, queueId: queueId)
        let _: DequeueResult = try await ws.send(method: "agent.dequeuePrompt", params: params)
    }

    /// Clear all queued prompts for the current session.
    func clearQueue() async throws {
        let (ws, sessionId) = try requireTransport().requireSession()
        let params = ClearQueueParams(sessionId: sessionId)
        let _: ClearQueueResult = try await ws.send(method: "agent.clearQueue", params: params)
    }

    func abort() async throws {
        guard let (ws, sessionId) = try? requireTransport().requireSession() else { return }

        let params = AgentAbortParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "agent.abort", params: params)
        logger.info("Aborted agent", category: .chat)
    }

    // MARK: - Tool Result Methods

    /// Send a tool result for interactive tools like AskUserQuestion.
    /// This unblocks the agent which is waiting for user input.
    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {
        let ws = try requireTransport().requireConnection()

        let params = ToolResultParams(sessionId: sessionId, toolCallId: toolCallId, result: result)
        logger.info("[TOOL_RESULT] Sending tool result: sessionId=\(sessionId), toolCallId=\(toolCallId)", category: .session)

        let response: ToolResultResponse = try await ws.send(
            method: "tool.result",
            params: params
        )

        logger.info("[TOOL_RESULT] Tool result sent successfully: success=\(response.success)", category: .session)
    }
}
