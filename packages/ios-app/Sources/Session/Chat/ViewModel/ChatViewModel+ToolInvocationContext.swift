import Foundation

// MARK: - ToolInvocationContext Conformance

/// Extension to make ChatViewModel conform to ToolInvocationContext.
/// This provides the coordinator with access to the necessary state and methods.
extension ChatViewModel: ToolInvocationContext {

    // MARK: - Protocol Properties
    // Most properties are already defined in ChatViewModel.swift:
    // - messages: [ChatMessage]
    // - currentTurnToolMessageIds: Set<UUID>

    // MARK: - Protocol Methods

    /// Enqueue a tool start for ordered processing (ToolInvocationContext)
    func enqueueToolInvocationStart(_ data: UIUpdateQueue.ToolInvocationStartData) {
        uiUpdateQueue.enqueueToolInvocationStart(data)
    }

    /// Enqueue a tool end for ordered processing (ToolInvocationContext)
    func enqueueToolInvocationEnd(_ data: UIUpdateQueue.ToolInvocationEndData) {
        uiUpdateQueue.enqueueToolInvocationEnd(data)
    }

    /// Reset thinking state for a new thinking block (ToolInvocationContext)
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock() {
        thinkingState.clearCurrentStreaming()
        thinkingMessageId = nil
    }

    /// Mark the current thinking message as no longer streaming (ToolInvocationContext)
    func finalizeThinkingMessageIfNeeded() {
        markThinkingMessageCompleteIfNeeded()
    }
}
