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
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws

    func abort() async throws

    func getState() async throws -> AgentStateResult

    func getState(sessionId: String) async throws -> AgentStateResult

    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws
}

// MARK: - Default Parameter Extensions

extension AgentClientProtocol {
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil,
        spells: [Skill]? = nil
    ) async throws {
        try await sendPrompt(
            prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            skills: skills,
            spells: spells
        )
    }
}

// MARK: - AgentClient Conformance

extension AgentClient: AgentClientProtocol {}
