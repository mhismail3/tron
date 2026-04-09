import Foundation

// MARK: - ToolEventContext Conformance

/// Extension to make ChatViewModel conform to ToolEventContext.
/// This provides the coordinator with access to the necessary state and methods.
extension ChatViewModel: ToolEventContext {

    // MARK: - Protocol Properties
    // Most properties are already defined in ChatViewModel.swift:
    // - messages: [ChatMessage]
    // - currentToolMessages: [UUID: ChatMessage]
    // - currentTurnToolCalls: [ToolCallRecord]
    // - askUserQuestionCalledInTurn: Bool (via askUserQuestionState)

    // MARK: - Protocol Methods

    /// Enqueue a tool start for ordered processing (ToolEventContext)
    func enqueueToolStart(_ data: UIUpdateQueue.ToolStartData) {
        uiUpdateQueue.enqueueToolStart(data)
    }

    /// Enqueue a tool end for ordered processing (ToolEventContext)
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData) {
        uiUpdateQueue.enqueueToolEnd(data)
    }

    /// Reset thinking state for a new thinking block (ToolEventContext)
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock() {
        thinkingState.clearCurrentStreaming()
        thinkingMessageId = nil
    }

    /// Mark the current thinking message as no longer streaming (ToolEventContext)
    func finalizeThinkingMessageIfNeeded() {
        markThinkingMessageCompleteIfNeeded()
    }
}
