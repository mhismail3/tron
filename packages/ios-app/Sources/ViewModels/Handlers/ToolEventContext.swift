import Foundation

/// Protocol defining the context required by ToolEventCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of tool event handling.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
/// - ToolStateTracking: Tool call state (currentToolMessages, currentTurnToolCalls, etc.)
/// - MessageMutating: Centralized message array mutations with automatic index sync
///
/// Note: Streaming methods (flushPendingTextUpdates, finalizeStreamingMessage) are declared
/// directly rather than inheriting StreamingManaging, since resetStreamingManager is not needed.
@MainActor
protocol ToolEventContext: LoggingContext, ToolStateTracking, MessageMutating {

    // MARK: - Messages State

    /// Running tool counter for O(1) hasRunningTools check
    var runningToolCount: Int { get set }

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

    /// Update an existing message in the MessageWindowManager
    func updateInMessageWindow(_ message: ChatMessage)

    /// Enqueue a tool start for ordered processing
    func enqueueToolStart(_ data: UIUpdateQueue.ToolStartData)

    /// Enqueue a tool end for ordered processing
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData)

    // MARK: - AskUserQuestion

    /// Open the AskUserQuestion sheet for a tool call
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData)

    // MARK: - GetConfirmation

    /// Open the GetConfirmation sheet for a tool call
    func openGetConfirmationSheet(for data: GetConfirmationToolData)

    // MARK: - Thinking State

    /// Reset thinking state for a new thinking block
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock()

    /// Mark the current thinking message as no longer streaming (if present)
    func finalizeThinkingMessageIfNeeded()
}
