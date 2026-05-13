import Foundation

/// Protocol defining the context required by CapabilityInvocationCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of capability invocation event handling.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
/// - ToolStateTracking: Capability invocation state (currentToolMessages, currentTurnCapabilityInvocations, etc.)
/// - MessageMutating: Centralized message array mutations with automatic index sync
///
/// Note: Streaming methods (flushPendingTextUpdates, finalizeStreamingMessage) are declared
/// directly rather than inheriting StreamingManaging, since resetStreamingManager is not needed.
@MainActor
protocol CapabilityInvocationContext: LoggingContext, ToolStateTracking, MessageMutating {

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
    func makeCapabilityInvocationVisible(_ invocationId: String)

    /// Enqueue a capability start for ordered processing
    func enqueueCapabilityInvocationStart(_ data: UIUpdateQueue.ToolStartData)

    /// Enqueue a capability end for ordered processing
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData)

    // MARK: - AskUserQuestion

    /// Open the AskUserQuestion sheet for a capability invocation
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData)

    // MARK: - Thinking State

    /// Reset thinking state for a new thinking block
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock()

    /// Mark the current thinking message as no longer streaming (if present)
    func finalizeThinkingMessageIfNeeded()
}
