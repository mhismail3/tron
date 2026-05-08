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

    func sendToolResult(
        sessionId: String,
        toolCallId: String,
        result: AskUserQuestionResult,
        idempotencyKey: EngineIdempotencyKey
    ) async throws

    // Session-scoped skill methods
    func activateSkill(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws -> SkillActivateResult
    func deactivateSkill(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws -> SkillDeactivateResult
    func activeSkills() async throws -> SkillActiveResult
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
