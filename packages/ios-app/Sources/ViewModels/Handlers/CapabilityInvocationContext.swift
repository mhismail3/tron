import Foundation

/// Protocol defining the context required by CapabilityInvocationCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of capability invocation event handling.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
/// - CapabilityInvocationStateTracking: Capability invocation state (currentCapabilityInvocationMessages, currentTurnCapabilityInvocations, etc.)
/// - MessageMutating: Centralized message array mutations with automatic index sync
///
/// Note: Streaming methods (flushPendingTextUpdates, finalizeStreamingMessage) are declared
/// directly rather than inheriting StreamingManaging, since resetStreamingManager is not needed.
@MainActor
protocol CapabilityInvocationContext: LoggingContext, CapabilityInvocationStateTracking, MessageMutating {

    // MARK: - Messages State

    /// Running capability counter for O(1) hasRunningCapabilityInvocations check
    var runningCapabilityInvocationCount: Int { get set }

    // MARK: - Streaming Management

    /// Flush any pending text updates before capability processing
    func flushPendingTextUpdates()

    /// Finalize the current streaming message
    func finalizeStreamingMessage()

    // MARK: - UI Coordination

    /// Make a capability visible for animation
    func makeCapabilityInvocationVisible(_ invocationId: String)

    /// Enqueue a capability start for ordered processing
    func enqueueCapabilityInvocationStart(_ data: UIUpdateQueue.CapabilityInvocationStartData)

    /// Enqueue a capability end for ordered processing
    func enqueueCapabilityInvocationEnd(_ data: UIUpdateQueue.CapabilityInvocationEndData)

    // MARK: - UserInteraction

    /// Open the UserInteraction sheet for a capability invocation
    func openUserInteractionSheet(for data: UserInteractionInvocationData)

    // MARK: - Thinking State

    /// Reset thinking state for a new thinking block
    /// Called after capability completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock()

    /// Mark the current thinking message as no longer streaming (if present)
    func finalizeThinkingMessageIfNeeded()
}
