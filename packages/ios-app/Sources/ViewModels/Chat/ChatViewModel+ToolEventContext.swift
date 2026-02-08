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

    /// Update an existing message in the MessageWindowManager (ToolEventContext)
    func updateInMessageWindow(_ message: ChatMessage) {
        messageWindowManager.updateMessage(message)
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
    /// Also auto-shows the browser window when a browser tool is detected.
    @discardableResult
    func updateBrowserStatusIfNeeded() -> Bool {
        let shouldShow = !browserState.userDismissedBrowserThisTurn
        if browserState.browserStatus == nil {
            browserState.browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
        }
        // Auto-show browser window when browser tool is detected (unless user dismissed this turn)
        // This follows the same pattern as BrowserCoordinator.handleBrowserFrame and
        // ChatViewModel+Events.extractAndDisplayBrowserScreenshot
        if shouldShow && !browserState.showBrowserWindow {
            browserState.showBrowserWindow = true
            logger.info("Browser window auto-shown on browser tool start", category: .events)
        }
        return shouldShow
    }

    /// Start browser stream if not already streaming (ToolEventContext)
    func startBrowserStreamIfNeeded() {
        if browserState.browserStatus?.isStreaming == true || browserState.userDismissedBrowserThisTurn {
            return
        }
        Task {
            await startBrowserStream()
        }
    }

    /// Reset thinking state for a new thinking block (ToolEventContext)
    /// Called after tool completion so subsequent thinking starts fresh
    func resetThinkingForNewBlock() {
        eventHandler.resetThinkingState()
        thinkingMessageId = nil
    }

    /// Mark the current thinking message as no longer streaming (ToolEventContext)
    func finalizeThinkingMessageIfNeeded() {
        markThinkingMessageCompleteIfNeeded()
    }
}
