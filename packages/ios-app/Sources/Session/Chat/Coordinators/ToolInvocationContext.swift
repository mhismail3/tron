import Foundation

/// Protocol defining the context required by ToolInvocationCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of tool invocation event handling.
@MainActor
protocol ToolInvocationContext: ChatCoordinatorContext, MessageMutating {

    // MARK: - Messages State

    var currentTurnToolMessageIds: Set<UUID> { get set }

    /// Running tool counter for O(1) hasRunningToolInvocations check
    var runningToolInvocationCount: Int { get set }

    /// Latest unresolved native question. Transcript state remains canonical;
    /// this value only requests foreground presentation.
    var pendingUserInputRequest: UserInputRequest? { get set }

    /// Set only by a newly arriving live tool-start event. Reconstructed
    /// pending requests intentionally leave this nil so reopening a chat does
    /// not repeatedly force-present a question sheet.
    var userInputAutoPresentationInvocationId: String? { get set }

    // MARK: - Streaming Management

    /// Flush any pending text updates before tool processing
    func flushPendingTextUpdates()

    /// Finalize the current streaming message
    func finalizeStreamingMessage()

    // MARK: - UI Coordination

    /// Make a tool visible for animation
    func makeToolInvocationVisible(_ invocationId: String)

    /// Enqueue a tool start for ordered processing
    func enqueueToolInvocationStart(_ data: UIUpdateQueue.ToolInvocationStartData)

    /// Enqueue a tool end for ordered processing
    func enqueueToolInvocationEnd(_ data: UIUpdateQueue.ToolInvocationEndData)

    // MARK: - Thinking State

    /// Reset thinking state for a new thinking block
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock()

    /// Mark the current thinking message as no longer streaming (if present)
    func finalizeThinkingMessageIfNeeded()
}
