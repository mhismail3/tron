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
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws

    /// Abort the current agent operation.
    func abort(idempotencyKey: EngineIdempotencyKey) async throws

    /// Send a tool result for interactive tools.
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - toolCallId: The tool call ID to respond to
    ///   - result: The result of the user interaction
    func sendToolResult(
        sessionId: String,
        toolCallId: String,
        result: AskUserQuestionResult,
        idempotencyKey: EngineIdempotencyKey
    ) async throws
}
