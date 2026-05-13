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
        reasoningLevel: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        try await agentClient.sendPrompt(
            prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            idempotencyKey: idempotencyKey
        )
    }

    func abort(idempotencyKey: EngineIdempotencyKey) async throws {
        try await agentClient.abort(idempotencyKey: idempotencyKey)
    }

}
