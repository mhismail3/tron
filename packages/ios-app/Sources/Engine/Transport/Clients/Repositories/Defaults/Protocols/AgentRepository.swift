import Foundation

// MARK: - Agent Repository Protocol

/// Repository protocol for agent operations.
/// Keeps session consumers transport-agnostic and is fulfilled directly by `AgentClient`.
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

    /// Ask the server to cancel the current agent operation.
    /// Returns `true` when an active run matched the request. Terminal events
    /// remain authoritative for the run's final outcome.
    @discardableResult
    func abort(idempotencyKey: EngineIdempotencyKey) async throws -> Bool

    /// Abort one in-flight capability invocation without stopping the whole turn.
    @discardableResult
    func abortCapabilityInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> Bool
}
