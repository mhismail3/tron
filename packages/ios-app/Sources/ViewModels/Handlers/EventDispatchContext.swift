import Foundation

// MARK: - Domain-Specific Handler Protocols

@MainActor protocol StreamingEventHandler: AnyObject {
    func handleTextDelta(_ delta: String)
    func handleThinkingDelta(_ delta: String)
}

@MainActor protocol CapabilityInvocationEventHandler: AnyObject {
    func handleCapabilityInvocationGenerating(_ result: CapabilityInvocationGeneratingPlugin.Result)
    func handleCapabilityInvocationStarted(_ result: CapabilityInvocationStartedPlugin.Result)
    func handleCapabilityInvocationOutput(_ result: CapabilityInvocationOutputPlugin.Result)
    func handleCapabilityInvocationProgress(_ result: CapabilityInvocationProgressPlugin.Result)
    func handleCapabilityInvocationCompleted(_ result: CapabilityInvocationCompletedPlugin.Result)
    func handleCapabilityPauseRequested(_ result: CapabilityPauseRequestedPlugin.Result)
    func handleCapabilityPauseResolved(_ result: CapabilityPauseResolvedPlugin.Result)
    func handleCapabilityRunStatus(_ result: CapabilityRunStatusPlugin.Result)
}

@MainActor protocol TurnLifecycleEventHandler: AnyObject {
    func handleTurnStart(_ result: TurnStartPlugin.Result)
    func handleTurnEnd(_ result: TurnEndPlugin.Result)
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
}

@MainActor protocol DisplayStreamEventHandler: AnyObject {
    func handleDisplayFrame(_ result: DisplayFramePlugin.Result)
}

@MainActor protocol ProcessEventHandler: AnyObject {
    func handleProcessSpawned(_ result: ProcessSpawnedPlugin.Result)
    func handleProcessCompleted(_ result: ProcessCompletedPlugin.Result)
    func handleProcessStatusUpdate(_ result: ProcessStatusUpdatePlugin.Result)
    func handleJobBackgrounded(_ result: JobBackgroundedPlugin.Result)
}

@MainActor protocol HookEventHandler: AnyObject {
    func handleLlmHookResult(_ result: LlmHookResultPlugin.Result)
}

@MainActor protocol QueueEventHandler: AnyObject {
    func handleMessageQueued(_ result: MessageQueuedPlugin.Result)
    func handleMessageDequeued(_ result: MessageDequeuedPlugin.Result)
    func handleQueuedMessageSent(_ result: QueuedMessageSentPlugin.Result)
}

@MainActor protocol EventDispatchLogger: AnyObject {
    func logWarning(_ message: String)
    func logDebug(_ message: String)
}

// MARK: - Composed Target

/// Full dispatch target — ChatViewModel conforms to this.
/// Composes all domain protocols into a single conformance point.
@MainActor protocol EventDispatchTarget:
    StreamingEventHandler, CapabilityInvocationEventHandler, TurnLifecycleEventHandler,
    ContextEventHandler,
    ServerEventHandler,
    DisplayStreamEventHandler, ProcessEventHandler, HookEventHandler,
    QueueEventHandler, EventDispatchLogger {}
