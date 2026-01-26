import Foundation

/// Client for agent-related RPC methods.
/// Handles prompts, abort, state queries, and tool results.
@MainActor
final class AgentClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Agent Methods

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil,
        spells: [Skill]? = nil
    ) async throws {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (ws, sessionId) = try transport.requireSession()

        let params = AgentPromptParams(
            sessionId: sessionId,
            prompt: prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            skills: skills,
            spells: spells
        )

        let result: AgentPromptResult = try await ws.send(
            method: "agent.prompt",
            params: params
        )

        if !result.acknowledged {
            logger.warning("Prompt not acknowledged by server", category: .chat)
        }
    }

    func abort() async throws {
        guard let transport else { return }
        guard let (ws, sessionId) = try? transport.requireSession() else { return }

        let params = AgentAbortParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "agent.abort", params: params)
        logger.info("Aborted agent", category: .chat)
    }

    func getState() async throws -> AgentStateResult {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (ws, sessionId) = try transport.requireSession()

        let params = AgentStateParams(sessionId: sessionId)
        return try await ws.send(method: "agent.getState", params: params)
    }

    /// Get agent state for a specific session (used for dashboard polling)
    func getState(sessionId: String) async throws -> AgentStateResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = AgentStateParams(sessionId: sessionId)
        return try await ws.send(method: "agent.getState", params: params)
    }

    // MARK: - Tool Result Methods

    /// Send a tool result for interactive tools like AskUserQuestion.
    /// This unblocks the agent which is waiting for user input.
    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {
        guard let transport else {
            logger.error("[TOOL_RESULT] Cannot send tool result - WebSocket not connected", category: .session)
            throw RPCClientError.connectionNotEstablished
        }
        let ws = try transport.requireConnection()

        let params = ToolResultParams(sessionId: sessionId, toolCallId: toolCallId, result: result)
        logger.info("[TOOL_RESULT] Sending tool result: sessionId=\(sessionId), toolCallId=\(toolCallId)", category: .session)

        let response: ToolResultResponse = try await ws.send(
            method: "tool.result",
            params: params
        )

        logger.info("[TOOL_RESULT] Tool result sent successfully: success=\(response.success)", category: .session)
    }
}
