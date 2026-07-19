import Foundation

/// Protocol defining the context required by TurnLifecycleCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of turn lifecycle handling.
@MainActor
protocol TurnLifecycleContext: ChatCoordinatorContext, MessageMutating {

    // MARK: - Turn Tracking State

    /// ID of the thinking message for the current turn
    var thinkingMessageId: UUID? { get set }

    /// Index in messages array where the current turn started
    var turnStartMessageIndex: Int? { get set }

    /// Message identities belonging to the current turn's capability invocations.
    var currentTurnCapabilityMessageIds: Set<UUID> { get set }

    /// ID of the first text message created in this turn
    var firstTextMessageIdForTurn: UUID? { get set }

    /// ID of the currently streaming message (from StreamingManager)
    var streamingMessageId: UUID? { get }

    /// Whether there is active streaming (streamingMessageId != nil && !streamingText.isEmpty)
    var hasActiveStreaming: Bool { get }

    func flushPendingTextUpdates()
    func finalizeStreamingMessage()
    func resetStreamingManager()

    // MARK: - Session State

    /// Current model being used
    var currentModel: String { get }

    // MARK: - Thinking State

    /// Notify ThinkingState of new turn
    func startThinkingTurn(_ turnNumber: Int, model: String)

    /// Persist thinking content for the completed turn
    func endThinkingTurn() async

    // MARK: - UI Coordination

    /// Enqueue a turn boundary event for UI update queue
    func enqueueTurnBoundary(_ data: UIUpdateQueue.TurnBoundaryData)

    /// Reset animation coordinator capability state
    func resetAnimationCoordinatorCapabilityState()

    /// Flush the UI update queue
    func flushUIUpdateQueue()

    /// Reset the UI update queue
    func resetUIUpdateQueue()

    // MARK: - Context State

    /// Update context state from token record
    func updateContextStateFromTokenRecord(_ record: TokenRecord)

    /// Set the current context window limit
    func setContextStateCurrentContextWindow(_ limit: Int)

    /// Accumulate token usage for billing
    func accumulateTokens(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cost: Double)

    // MARK: - Session Persistence

    /// Persist the context-owned accumulated token totals and this turn's context size.
    func persistAccumulatedSessionTokens(lastTurnInputTokens: Int) async throws

    /// Update the session's processing state in the session list/database.
    func setSessionProcessing(_ isProcessing: Bool)

    /// Update session activity summary in database
    func updateSessionActivitySummary(lastAssistantResponse: String?)
}
