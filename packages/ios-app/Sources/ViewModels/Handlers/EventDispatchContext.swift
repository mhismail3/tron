import Foundation

/// Protocol defining the handler methods for dispatched events.
/// ChatViewModel conforms to this protocol, allowing EventDispatchCoordinator
/// to route events to the appropriate handlers without tight coupling.
@MainActor
protocol EventDispatchContext: AnyObject {
    // MARK: - Text/Thinking

    /// Handle text delta streaming event
    func handleTextDelta(_ delta: String)

    /// Handle thinking delta streaming event
    func handleThinkingDelta(_ delta: String)

    // MARK: - Tools

    /// Handle tool start event
    func handleToolStart(_ result: ToolStartPlugin.Result)

    /// Handle tool end event
    func handleToolEnd(_ result: ToolEndPlugin.Result)

    // MARK: - Turn Lifecycle

    /// Handle turn start event
    func handleTurnStart(_ result: TurnStartPlugin.Result)

    /// Handle turn end event
    func handleTurnEnd(_ result: TurnEndPlugin.Result)

    /// Handle agent turn event (full message history)
    func handleAgentTurn(_ result: AgentTurnPlugin.Result)

    /// Handle completion event
    func handleComplete()

    /// Handle agent error event
    func handleAgentError(_ message: String)

    // MARK: - Context Operations

    /// Handle context compaction event
    func handleCompaction(_ result: CompactionPlugin.Result)

    /// Handle context cleared event
    func handleContextCleared(_ result: ContextClearedPlugin.Result)

    /// Handle message deleted event
    func handleMessageDeleted(_ result: MessageDeletedPlugin.Result)

    /// Handle skill removed event
    func handleSkillRemoved(_ result: SkillRemovedPlugin.Result)

    // MARK: - Plan Mode

    /// Handle plan mode entered event
    func handlePlanModeEntered(_ result: PlanModeEnteredPlugin.Result)

    /// Handle plan mode exited event
    func handlePlanModeExited(_ result: PlanModeExitedPlugin.Result)

    // MARK: - Browser

    /// Handle browser frame event
    func handleBrowserFrame(_ result: BrowserFramePlugin.Result)

    /// Handle browser closed event
    func handleBrowserClosed(_ sessionId: String)

    // MARK: - Subagents

    /// Handle subagent spawned event
    func handleSubagentSpawned(_ result: SubagentSpawnedPlugin.Result)

    /// Handle subagent status event
    func handleSubagentStatus(_ result: SubagentStatusPlugin.Result)

    /// Handle subagent completed event
    func handleSubagentCompleted(_ result: SubagentCompletedPlugin.Result)

    /// Handle subagent failed event
    func handleSubagentFailed(_ result: SubagentFailedPlugin.Result)

    /// Handle subagent forwarded event
    func handleSubagentEvent(_ result: SubagentEventPlugin.Result)

    // MARK: - UI Canvas

    /// Handle UI render start event
    func handleUIRenderStart(_ result: UIRenderStartPlugin.Result)

    /// Handle UI render chunk event
    func handleUIRenderChunk(_ result: UIRenderChunkPlugin.Result)

    /// Handle UI render complete event
    func handleUIRenderComplete(_ result: UIRenderCompletePlugin.Result)

    /// Handle UI render error event
    func handleUIRenderError(_ result: UIRenderErrorPlugin.Result)

    /// Handle UI render retry event
    func handleUIRenderRetry(_ result: UIRenderRetryPlugin.Result)

    // MARK: - Todo

    /// Handle todos updated event
    func handleTodosUpdated(_ result: TodosUpdatedPlugin.Result)

    // MARK: - Logging

    /// Log a warning message
    func logWarning(_ message: String)

    /// Log a debug message
    func logDebug(_ message: String)
}
