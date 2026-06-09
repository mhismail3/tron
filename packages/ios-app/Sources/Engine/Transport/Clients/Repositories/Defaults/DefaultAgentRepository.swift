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
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        try await agentClient.sendPrompt(
            prompt,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            idempotencyKey: idempotencyKey
        )
    }

    func abort(idempotencyKey: EngineIdempotencyKey) async throws {
        try await agentClient.abort(idempotencyKey: idempotencyKey)
    }

    func abortCapabilityInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> Bool {
        try await agentClient.abortCapabilityInvocation(
            invocationId: invocationId,
            idempotencyKey: idempotencyKey
        )
    }

}
