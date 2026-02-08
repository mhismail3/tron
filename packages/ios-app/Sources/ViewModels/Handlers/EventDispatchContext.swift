import Foundation

// MARK: - Domain-Specific Handler Protocols

@MainActor protocol StreamingEventHandler: AnyObject {
    func handleTextDelta(_ delta: String)
    func handleThinkingDelta(_ delta: String)
}

@MainActor protocol ToolEventHandler: AnyObject {
    func handleToolGenerating(_ result: ToolGeneratingPlugin.Result)
    func handleToolStart(_ result: ToolStartPlugin.Result)
    func handleToolEnd(_ result: ToolEndPlugin.Result)
}

@MainActor protocol TurnLifecycleEventHandler: AnyObject {
    func handleTurnStart(_ result: TurnStartPlugin.Result)
    func handleTurnEnd(_ result: TurnEndPlugin.Result)
    func handleAgentTurn(_ result: AgentTurnPlugin.Result)
    func handleComplete()
    func handleAgentReady()
    func handleAgentError(_ message: String)
}

@MainActor protocol ContextEventHandler: AnyObject {
    func handleCompactionStarted(_ result: CompactionStartedPlugin.Result)
    func handleCompaction(_ result: CompactionPlugin.Result)
    func handleMemoryUpdated(_ result: MemoryUpdatedPlugin.Result)
    func handleContextCleared(_ result: ContextClearedPlugin.Result)
    func handleMessageDeleted(_ result: MessageDeletedPlugin.Result)
    func handleSkillRemoved(_ result: SkillRemovedPlugin.Result)
}

@MainActor protocol BrowserEventHandler: AnyObject {
    func handleBrowserFrame(_ result: BrowserFramePlugin.Result)
    func handleBrowserClosed(_ sessionId: String)
}

@MainActor protocol SubagentEventHandler: AnyObject {
    func handleSubagentSpawned(_ result: SubagentSpawnedPlugin.Result)
    func handleSubagentStatus(_ result: SubagentStatusPlugin.Result)
    func handleSubagentCompleted(_ result: SubagentCompletedPlugin.Result)
    func handleSubagentFailed(_ result: SubagentFailedPlugin.Result)
    func handleSubagentEvent(_ result: SubagentEventPlugin.Result)
    func handleSubagentResultAvailable(_ result: SubagentResultAvailablePlugin.Result)
}

@MainActor protocol UICanvasEventHandler: AnyObject {
    func handleUIRenderStart(_ result: UIRenderStartPlugin.Result)
    func handleUIRenderChunk(_ result: UIRenderChunkPlugin.Result)
    func handleUIRenderComplete(_ result: UIRenderCompletePlugin.Result)
    func handleUIRenderError(_ result: UIRenderErrorPlugin.Result)
    func handleUIRenderRetry(_ result: UIRenderRetryPlugin.Result)
}

@MainActor protocol TodoEventHandler: AnyObject {
    func handleTodosUpdated(_ result: TodosUpdatedPlugin.Result)
}

@MainActor protocol EventDispatchLogger: AnyObject {
    func logWarning(_ message: String)
    func logDebug(_ message: String)
}

// MARK: - Composed Target

/// Full dispatch target — ChatViewModel conforms to this.
/// Composes all domain protocols into a single conformance point.
@MainActor protocol EventDispatchTarget:
    StreamingEventHandler, ToolEventHandler, TurnLifecycleEventHandler,
    ContextEventHandler, BrowserEventHandler, SubagentEventHandler,
    UICanvasEventHandler, TodoEventHandler, EventDispatchLogger {}

