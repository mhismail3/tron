import Foundation

/// Protocol defining the context required by TurnLifecycleCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of turn lifecycle handling.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
/// - ProcessingTrackable: Processing state and setSessionProcessing
/// - StreamingManaging: Streaming state management
/// - ToolStateTracking: Tool call state (currentToolMessages, currentTurnToolCalls, etc.)
/// - BrowserManaging: Browser session management
///
/// Note: SessionIdentifiable was removed as sessionId is not used by TurnLifecycleCoordinator.
/// Note: streamingText removed - passed as parameter to handleComplete instead.
/// Note: updateTotalTokenUsage removed - not called by coordinator.
@MainActor
protocol TurnLifecycleContext: LoggingContext, ProcessingTrackable, StreamingManaging, ToolStateTracking, BrowserManaging {

    // MARK: - Messages State

    /// Messages array to update with metadata
    var messages: [ChatMessage] { get set }

    // MARK: - Turn Tracking State

    /// ID of the thinking message for the current turn
    var thinkingMessageId: UUID? { get set }

    /// Index in messages array where the current turn started
    var turnStartMessageIndex: Int? { get set }

    /// ID of the first text message created in this turn
    var firstTextMessageIdForTurn: UUID? { get set }

    /// ID of the currently streaming message (from StreamingManager)
    var streamingMessageId: UUID? { get }

    /// Whether there is active streaming (streamingMessageId != nil && !streamingText.isEmpty)
    var hasActiveStreaming: Bool { get }

    // MARK: - Session State

    /// Current model being used
    var currentModel: String { get }

    /// ID of the catching-up notification message
    var catchingUpMessageId: UUID? { get set }

    /// Whether user dismissed browser this turn
    var userDismissedBrowserThisTurn: Bool { get set }

    // MARK: - Thinking State

    /// Notify ThinkingState of new turn
    func startThinkingTurn(_ turnNumber: Int, model: String)

    /// Persist thinking content for the completed turn
    func endThinkingTurn() async

    // MARK: - UI Coordination

    /// Enqueue a turn boundary event for UI update queue
    func enqueueTurnBoundary(_ data: UIUpdateQueue.TurnBoundaryData)

    /// Reset animation coordinator tool state
    func resetAnimationCoordinatorToolState()

    /// Flush the UI update queue
    func flushUIUpdateQueue()

    /// Reset the UI update queue
    func resetUIUpdateQueue()

    // MARK: - Context State

    /// Update context state from normalized usage
    func updateContextStateFromNormalizedUsage(_ usage: NormalizedTokenUsage)

    /// Set the current context window limit
    func setContextStateCurrentContextWindow(_ limit: Int)

    /// Accumulate token usage for billing
    func accumulateTokens(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cost: Double)

    /// Refresh context from server
    func refreshContextFromServer() async

    // MARK: - Session Persistence

    /// Update session tokens in database
    func updateSessionTokens(inputTokens: Int, outputTokens: Int, lastTurnInputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, cost: Double) throws

    /// Update session dashboard info in database
    func updateSessionDashboardInfo(lastAssistantResponse: String?, lastToolCount: Int?)
}
