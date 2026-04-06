import Foundation

/// Client for agent-related RPC methods.
/// Handles prompts, abort, state queries, and tool results.
@MainActor
final class AgentClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Access transport safely, throwing if deallocated during server change.
    private func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }

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
