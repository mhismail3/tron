import Foundation

// MARK: - Default Agent Repository

/// Default implementation of AgentRepository.
/// Wraps AgentClient for agent operations.
@MainActor
final class DefaultAgentRepository: AgentRepository {
    private let agentClient: AgentClient

    // MARK: - Initialization

    init(agentClient: AgentClient) {
        self.agentClient = agentClient
    }

    // MARK: - AgentRepository

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil
    ) async throws {
        try await agentClient.sendPrompt(
            prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel
        )
    }

    func abort() async throws {
        try await agentClient.abort()
    }

    func getState() async throws -> AgentStateResult {
        try await agentClient.getState()
    }

    func getState(sessionId: String) async throws -> AgentStateResult {
        try await agentClient.getState(sessionId: sessionId)
    }

    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {
        try await agentClient.sendToolResult(sessionId: sessionId, toolCallId: toolCallId, result: result)
    }
}
