import Foundation

/// Extension making ChatViewModel conform to EventDispatchContext.
/// This provides the bridge between the EventDispatchCoordinator and
/// the existing event handler methods in ChatViewModel.
///
/// Most handler methods are already implemented in ChatViewModel+Events.swift
/// and ChatViewModel+Browser.swift. This extension only provides wrappers
/// for methods that need to adapt plugin Result types to existing signatures.
extension ChatViewModel: EventDispatchContext {

    // MARK: - Browser Event Wrappers

    /// Handle browser frame event - wraps the existing handleBrowserFrameResult
    func handleBrowserFrame(_ result: BrowserFramePlugin.Result) {
        handleBrowserFrameResult(result)
    }

    // Note: handleBrowserClosed(_ sessionId: String) is already implemented
    // in ChatViewModel+Browser.swift

    // MARK: - Subagent Event Wrappers

    /// Handle subagent spawned event - wraps the existing handleSubagentSpawnedResult
    func handleSubagentSpawned(_ result: SubagentSpawnedPlugin.Result) {
        handleSubagentSpawnedResult(result)
    }

    /// Handle subagent status event - wraps the existing handleSubagentStatusResult
    func handleSubagentStatus(_ result: SubagentStatusPlugin.Result) {
        handleSubagentStatusResult(result)
    }

    /// Handle subagent completed event - wraps the existing handleSubagentCompletedResult
    func handleSubagentCompleted(_ result: SubagentCompletedPlugin.Result) {
        handleSubagentCompletedResult(result)
    }

    /// Handle subagent failed event - wraps the existing handleSubagentFailedResult
    func handleSubagentFailed(_ result: SubagentFailedPlugin.Result) {
        handleSubagentFailedResult(result)
    }

    /// Handle subagent forwarded event - wraps the existing handleSubagentForwardedEventResult
    func handleSubagentEvent(_ result: SubagentEventPlugin.Result) {
        handleSubagentForwardedEventResult(result)
    }

    /// Handle subagent result available event - wraps the existing handleSubagentResultAvailableResult
    func handleSubagentResultAvailable(_ result: SubagentResultAvailablePlugin.Result) {
        handleSubagentResultAvailableResult(result)
    }

    // Note: logWarning and logDebug are already implemented in ChatViewModel.swift
    // via LoggingContext protocol conformance
}
