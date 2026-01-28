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
    // - browserStatus: BrowserGetStatusResult? (via browserState)
    // - renderAppUIChipTracker: RenderAppUIChipTracker

    /// Safari URL for in-app browser (ToolEventContext)
    var safariURL: URL? {
        get { browserState.safariURL }
        set { browserState.safariURL = newValue }
    }

    // MARK: - Protocol Methods

    /// Append a message to the MessageWindowManager (ToolEventContext)
    func appendToMessageWindow(_ message: ChatMessage) {
        messageWindowManager.appendMessage(message)
    }

    /// Enqueue a tool start for ordered processing (ToolEventContext)
    func enqueueToolStart(_ data: UIUpdateQueue.ToolStartData) {
        uiUpdateQueue.enqueueToolStart(data)
    }

    /// Enqueue a tool end for ordered processing (ToolEventContext)
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData) {
        uiUpdateQueue.enqueueToolEnd(data)
    }

    /// Update browser status if needed - for browser tools (ToolEventContext)
    func updateBrowserStatusIfNeeded() {
        if browserState.browserStatus == nil {
            browserState.browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
        }
    }

    /// Reset thinking state for a new thinking block (ToolEventContext)
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock() {
        eventHandler.resetThinkingState()
        thinkingMessageId = nil
    }
}
