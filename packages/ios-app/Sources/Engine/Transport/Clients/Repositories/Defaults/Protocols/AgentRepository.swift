import Foundation

// MARK: - Agent Repository Protocol

/// Repository protocol for agent operations.
/// Provides abstraction over AgentClient for agent interactions.
@MainActor
protocol AgentRepository: AnyObject {
    /// Send a prompt to the agent.
    /// - Parameters:
    ///   - prompt: The text prompt to send
    ///   - attachments: Optional file attachments
    ///   - reasoningLevel: Optional reasoning level
    func sendPrompt(
        _ prompt: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws

    /// Abort the current agent operation.
    func abort(idempotencyKey: EngineIdempotencyKey) async throws

    /// Abort one in-flight capability invocation without stopping the whole turn.
    @discardableResult
    func abortCapabilityInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> Bool
}
