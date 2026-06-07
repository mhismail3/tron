import Foundation

/// Protocol for agent client operations.
/// Enables dependency injection for testing agent messaging.
@MainActor
protocol AgentClientProtocol {
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws

    func abort(idempotencyKey: EngineIdempotencyKey) async throws

}

// MARK: - Default Parameter Extensions

extension AgentClientProtocol {
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        try await sendPrompt(
            prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - AgentClient Conformance

extension AgentClient: AgentClientProtocol {}
