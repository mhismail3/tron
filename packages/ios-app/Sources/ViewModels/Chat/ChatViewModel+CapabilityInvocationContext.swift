import Foundation

// MARK: - CapabilityInvocationContext Conformance

/// Extension to make ChatViewModel conform to CapabilityInvocationContext.
/// This provides the coordinator with access to the necessary state and methods.
extension ChatViewModel: CapabilityInvocationContext {

    // MARK: - Protocol Properties
    // Most properties are already defined in ChatViewModel.swift:
    // - messages: [ChatMessage]
    // - currentToolMessages: [UUID: ChatMessage]
    // - currentTurnCapabilityInvocations: [CapabilityInvocationRecord]
    // - askUserQuestionCalledInTurn: Bool (via askUserQuestionState)

    // MARK: - Protocol Methods

    /// Enqueue a capability start for ordered processing (CapabilityInvocationContext)
    func enqueueCapabilityInvocationStart(_ data: UIUpdateQueue.ToolStartData) {
        uiUpdateQueue.enqueueCapabilityInvocationStart(data)
    }

    /// Enqueue a capability end for ordered processing (CapabilityInvocationContext)
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData) {
        uiUpdateQueue.enqueueToolEnd(data)
    }

    /// Reset thinking state for a new thinking block (CapabilityInvocationContext)
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock() {
        thinkingState.clearCurrentStreaming()
        thinkingMessageId = nil
    }

    /// Mark the current thinking message as no longer streaming (CapabilityInvocationContext)
    func finalizeThinkingMessageIfNeeded() {
        markThinkingMessageCompleteIfNeeded()
    }
}
