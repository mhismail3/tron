import Foundation

// MARK: - Agent Repository Protocol

/// Repository protocol for agent operations.
/// Keeps session consumers transport-agnostic and is fulfilled directly by `AgentClient`.
@MainActor
protocol AgentRepository: AnyObject {
    /// True only when the negotiated server advertises the complete reusable
    /// agent management surface. Older servers remain a calm read-only row.
    var supportsCoordinationManagement: Bool { get }

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

    /// Abort one in-flight tool invocation without stopping the whole turn.
    @discardableResult
    func abortToolInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> Bool

    /// Resolve one durable native question and admit the answers as the next
    /// user turn. The invocation id makes retries idempotent across reconnects.
    func answerUserInput(
        invocationId: String,
        answers: [UserInputAnswer],
        idempotencyKey: EngineIdempotencyKey
    ) async throws

    // MARK: Coordination management

    /// Read the canonical agent relationships visible from one owning
    /// session. Passing the session explicitly prevents a background sheet
    /// from accidentally following a later sidebar selection.
    func agentRelations(
        ownerSessionId: String,
        cursor: String?,
        limit: Int
    ) async throws -> AgentRelationsResultDTO

    func inspectAgent(
        ownerSessionId: String,
        agentId: String
    ) async throws -> AgentInspectDTO

    func agentAssignments(
        ownerSessionId: String,
        agentId: String,
        cursor: String?,
        limit: Int
    ) async throws -> AgentAssignmentsResultDTO

    func agentMessages(
        ownerSessionId: String,
        agentId: String,
        cursor: String?,
        limit: Int
    ) async throws -> AgentMessagesResultDTO

    func agentMessageDetail(
        ownerSessionId: String,
        agentId: String,
        messageId: String
    ) async throws -> AgentMessageDetailDTO

    /// Read one bounded page from an integrity-bound assignment result.
    func agentResult(
        ownerSessionId: String,
        agentId: String,
        resultId: String,
        pointer: String,
        offset: UInt64,
        limit: UInt8
    ) async throws -> AgentResultChunkDTO

    func sendOperatorMessage(
        ownerSessionId: String,
        agentId: String,
        content: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO

    func manageAgent(
        ownerSessionId: String,
        agentId: String,
        action: String,
        assignmentId: String?,
        cascade: Bool?,
        configuration: AnyCodable?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO

    func retryAgentAssignment(
        ownerSessionId: String,
        agentId: String,
        assignmentId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO

    func promoteAgent(
        ownerSessionId: String,
        agentId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO
}
