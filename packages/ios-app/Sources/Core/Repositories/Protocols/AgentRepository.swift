import Foundation

// MARK: - Agent Repository Protocol

/// Repository protocol for agent operations.
/// Provides abstraction over AgentClient for agent interactions.
@MainActor
protocol AgentRepository: AnyObject {
    /// Send a prompt to the agent.
    /// - Parameters:
    ///   - prompt: The text prompt to send
    ///   - images: Optional image attachments
    ///   - attachments: Optional file attachments
    ///   - reasoningLevel: Optional reasoning level
    ///   - skills: Optional skills to use
    ///   - spells: Optional spells to use
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws

    /// Abort the current agent operation.
    func abort() async throws

    /// Get the current agent state.
    /// - Returns: The current agent state
    func getState() async throws -> AgentStateResult

    /// Get agent state for a specific session.
    /// - Parameter sessionId: The session ID to get state for
    /// - Returns: The agent state for the session
    func getState(sessionId: String) async throws -> AgentStateResult

    /// Send a tool result for interactive tools.
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - toolCallId: The tool call ID to respond to
    ///   - result: The result of the user interaction
    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws
}
