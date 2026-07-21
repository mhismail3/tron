import Foundation

// MARK: - Domain-Specific Handler Protocols

@MainActor protocol StreamingEventHandler: AnyObject {
    func handleTextDelta(_ delta: String)
    func handleThinkingDelta(_ delta: String, kind: ThinkingDisplayKind)
    func handleThinkingEnd(_ thinking: String, kind: ThinkingDisplayKind)
}

@MainActor protocol ToolInvocationEventHandler: AnyObject {
    func handleToolInvocationGenerating(_ result: ToolInvocationGeneratingPlugin.Result)
    func handleToolInvocationStarted(_ result: ToolInvocationStartedPlugin.Result)
    func handleToolInvocationOutput(_ result: ToolInvocationOutputPlugin.Result)
    func handleToolInvocationProgress(_ result: ToolInvocationProgressPlugin.Result)
    func handleToolInvocationCompleted(_ result: ToolInvocationCompletedPlugin.Result)
}

@MainActor protocol TurnLifecycleEventHandler: AnyObject {
    func handleTurnStart(_ result: TurnStartPlugin.Result)
    func handleResponseComplete(_ result: AgentResponseCompletePlugin.Result)
    func handleTurnEnd(_ result: TurnEndPlugin.Result)
    func handleTurnFailed(_ result: TurnFailedPlugin.Result)
    func handleComplete()
    func handleAgentReady()
    func handleAgentError(_ message: String)
    func handleProviderError(_ result: ErrorPlugin.Result)
}

@MainActor protocol ContextEventHandler: AnyObject {
    func handleCompactionStarted(_ result: CompactionStartedPlugin.Result)
    func handleCompaction(_ result: CompactionPlugin.Result)
    func handleContextCleared(_ result: ContextClearedPlugin.Result)
    func handleMessageDeleted(_ result: MessageDeletedPlugin.Result)
}

@MainActor protocol ServerEventHandler: AnyObject {
    func handleServerRestarting(_ result: ServerRestartingPlugin.Result)
    func handleStreamRecoveryRequired(_ result: StreamRecoveryRequiredPlugin.Result)
}

@MainActor protocol EventDispatchLogger: AnyObject {
    func logWarning(_ message: String)
    func logDebug(_ message: String)
}

// MARK: - Composed Target

/// Full dispatch target — ChatViewModel conforms to this.
/// Composes all domain protocols into a single conformance point.
@MainActor protocol EventDispatchTarget:
    StreamingEventHandler, ToolInvocationEventHandler, TurnLifecycleEventHandler,
    ContextEventHandler,
    ServerEventHandler,
    EventDispatchLogger {}
