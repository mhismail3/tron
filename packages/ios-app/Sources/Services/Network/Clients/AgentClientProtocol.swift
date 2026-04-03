import Foundation

/// Protocol for agent client operations.
/// Enables dependency injection for testing agent messaging.
@MainActor
protocol AgentClientProtocol {
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?
    ) async throws

    func abort() async throws

    func getState() async throws -> AgentStateResult

    func getState(sessionId: String) async throws -> AgentStateResult

    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws

    // Session-scoped skill methods
    func activateSkill(_ skillName: String) async throws -> SkillActivateResult
    func deactivateSkill(_ skillName: String) async throws -> SkillDeactivateResult
    func castSpell(_ spellName: String) async throws -> SpellCastResult
    func activeSkills() async throws -> SkillActiveResult
}

// MARK: - Default Parameter Extensions

extension AgentClientProtocol {
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil
    ) async throws {
        try await sendPrompt(
            prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel
        )
    }
}

// MARK: - AgentClient Conformance

extension AgentClient: AgentClientProtocol {}
