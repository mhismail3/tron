import Foundation

/// Protocol defining the context required by TurnLifecycleCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of turn lifecycle handling.
@MainActor
protocol TurnLifecycleContext: LoggingContext {

    // MARK: - Messages State

    /// Messages array to update with metadata
    var messages: [ChatMessage] { get set }

    /// Map of current tool messages by message ID
    var currentToolMessages: [UUID: ChatMessage] { get set }

    /// Tool calls tracked for the current turn
    var currentTurnToolCalls: [ToolCallRecord] { get set }

    // MARK: - Turn Tracking State

    /// Whether AskUserQuestion was called in the current turn
    var askUserQuestionCalledInTurn: Bool { get set }

    /// ID of the thinking message for the current turn
    var thinkingMessageId: UUID? { get set }

    /// Index in messages array where the current turn started
    var turnStartMessageIndex: Int? { get set }

    /// ID of the first text message created in this turn
    var firstTextMessageIdForTurn: UUID? { get set }

    /// ID of the currently streaming message (from StreamingManager)
    var streamingMessageId: UUID? { get }

    /// Current streaming text content (from StreamingManager)
    var streamingText: String { get }

    /// Whether there is active streaming (streamingMessageId != nil && !streamingText.isEmpty)
    var hasActiveStreaming: Bool { get }

    // MARK: - Session State

    /// Current model being used
    var currentModel: String { get }

    /// Whether the agent is currently processing
    var isProcessing: Bool { get set }

    /// ID of the catching-up notification message
    var catchingUpMessageId: UUID? { get set }

    /// Whether user dismissed browser this turn
    var userDismissedBrowserThisTurn: Bool { get set }

    /// Current session ID
    var sessionId: String { get }

    // MARK: - Streaming Management

    /// Flush any pending text updates before state changes
    func flushPendingTextUpdates()

    /// Finalize the current streaming message
    func finalizeStreamingMessage()

    /// Reset the streaming manager
    func resetStreamingManager()

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

    // MARK: - Browser

    /// Close the browser session
    func closeBrowserSession()

    // MARK: - Context State

    /// Update context state from normalized usage
    func updateContextStateFromNormalizedUsage(_ usage: NormalizedTokenUsage)

    /// Set the current context window limit
    func setContextStateCurrentContextWindow(_ limit: Int)

    /// Accumulate token usage for billing
    func accumulateTokens(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cost: Double)

    /// Update total token usage display
    func updateTotalTokenUsage(contextSize: Int, outputTokens: Int, cacheRead: Int?, cacheCreation: Int?)

    /// Refresh context from server
    func refreshContextFromServer() async

    // MARK: - Session Persistence

    /// Update session tokens in database
    func updateSessionTokens(inputTokens: Int, outputTokens: Int, lastTurnInputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, cost: Double) throws

    /// Set session processing state in database
    func setSessionProcessing(_ isProcessing: Bool)

    /// Update session dashboard info in database
    func updateSessionDashboardInfo(lastAssistantResponse: String?, lastToolCount: Int?)
}
