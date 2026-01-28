import Foundation

/// Protocol defining the context required by ToolEventCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of tool event handling.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
/// - ToolStateTracking: Tool call state (currentToolMessages, currentTurnToolCalls, etc.)
///
/// Note: Streaming methods (flushPendingTextUpdates, finalizeStreamingMessage) are declared
/// directly rather than inheriting StreamingManaging, since resetStreamingManager is not needed.
@MainActor
protocol ToolEventContext: LoggingContext, ToolStateTracking {

    // MARK: - Messages State

    /// Messages array to append tool messages to
    var messages: [ChatMessage] { get set }

    // MARK: - State Objects

    /// Safari URL for in-app browser
    var safariURL: URL? { get set }

    /// RenderAppUI chip tracker for managing UI canvas chips
    var renderAppUIChipTracker: RenderAppUIChipTracker { get }

    // MARK: - Streaming Management

    /// Flush any pending text updates before tool processing
    func flushPendingTextUpdates()

    /// Finalize the current streaming message
    func finalizeStreamingMessage()

    // MARK: - UI Coordination

    /// Make a tool visible for animation
    func makeToolVisible(_ toolCallId: String)

    /// Append a message to the MessageWindowManager
    func appendToMessageWindow(_ message: ChatMessage)

    /// Enqueue a tool start for ordered processing
    func enqueueToolStart(_ data: UIUpdateQueue.ToolStartData)

    /// Enqueue a tool end for ordered processing
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData)

    // MARK: - AskUserQuestion

    /// Open the AskUserQuestion sheet for a tool call
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData)

    // MARK: - Browser

    /// Update browser status if needed (for browser tools)
    func updateBrowserStatusIfNeeded()

    // MARK: - Thinking State

    /// Reset thinking state for a new thinking block
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock()
}
