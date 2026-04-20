import Foundation

// MARK: - Domain-Specific Handler Protocols

@MainActor protocol StreamingEventHandler: AnyObject {
    func handleTextDelta(_ delta: String)
    func handleThinkingDelta(_ delta: String)
}

@MainActor protocol ToolEventHandler: AnyObject {
    func handleToolGenerating(_ result: ToolGeneratingPlugin.Result)
    func handleToolStart(_ result: ToolStartPlugin.Result)
    func handleToolOutput(_ result: ToolOutputPlugin.Result)
    func handleToolEnd(_ result: ToolEndPlugin.Result)
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
    func handleSkillActivated(_ result: SkillActivatedPlugin.Result)
    func handleSkillDeactivated(_ result: SkillDeactivatedPlugin.Result)
    func handleRulesActivated(_ result: RulesActivatedPlugin.Result)
}

@MainActor protocol SubagentEventHandler: AnyObject {
    func handleSubagentSpawned(_ result: SubagentSpawnedPlugin.Result)
    func handleSubagentStatus(_ result: SubagentStatusPlugin.Result)
    func handleSubagentCompleted(_ result: SubagentCompletedPlugin.Result)
    func handleSubagentFailed(_ result: SubagentFailedPlugin.Result)
    func handleSubagentEvent(_ result: SubagentEventPlugin.Result)
    func handleSubagentResultAvailable(_ result: SubagentResultAvailablePlugin.Result)
}

@MainActor protocol MemoryEventHandler: AnyObject {
    func handleMemoryUpdating(_ result: MemoryUpdatingPlugin.Result)
    func handleMemoryUpdated(_ result: MemoryUpdatedPlugin.Result)
    func handleMemoryAutoRetainTriggered(_ result: MemoryAutoRetainTriggeredPlugin.Result)
}

@MainActor protocol ServerEventHandler: AnyObject {
    func handleServerRestarting(_ result: ServerRestartingPlugin.Result)
}

@MainActor protocol WorktreeEventHandler: AnyObject {
    func handleWorktreeAcquired(_ result: WorktreeAcquiredPlugin.Result)
    func handleWorktreeCommit(_ result: WorktreeCommitPlugin.Result)
    func handleWorktreeMerged(_ result: WorktreeMergedPlugin.Result)
    func handleWorktreeReleased(_ result: WorktreeReleasedPlugin.Result)
    func handleWorktreeMainSynced(_ result: WorktreeMainSyncedPlugin.Result)
    func handleWorktreeSessionFinalized(_ result: WorktreeSessionFinalizedPlugin.Result)
    func handleWorktreeMergeStarted(_ result: WorktreeMergeStartedPlugin.Result)
    func handleWorktreeConflictDetected(_ result: WorktreeConflictDetectedPlugin.Result)
    func handleWorktreeConflictResolved(_ result: WorktreeConflictResolvedPlugin.Result)
    func handleWorktreeMergeContinued(_ result: WorktreeMergeContinuedPlugin.Result)
    func handleWorktreeMergeAborted(_ result: WorktreeMergeAbortedPlugin.Result)
    func handleWorktreePushed(_ result: WorktreePushedPlugin.Result)
    func handleWorktreePendingMergeDetected(_ result: WorktreePendingMergeDetectedPlugin.Result)
    func handleWorktreeRebasedOnMain(_ result: WorktreeRebasedOnMainPlugin.Result)
    func handleWorktreePostRebaseStashConflict(_ result: WorktreePostRebaseStashConflictPlugin.Result)
}

@MainActor protocol RepoEventHandler: AnyObject {
    func handleRepoLockAcquired(_ result: RepoLockAcquiredPlugin.Result)
    func handleRepoLockReleased(_ result: RepoLockReleasedPlugin.Result)
    func handleRepoMainAdvanced(_ result: RepoMainAdvancedPlugin.Result)
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
    StreamingEventHandler, ToolEventHandler, TurnLifecycleEventHandler,
    ContextEventHandler, SubagentEventHandler, MemoryEventHandler,
    ServerEventHandler, WorktreeEventHandler, RepoEventHandler,
    DisplayStreamEventHandler, ProcessEventHandler, HookEventHandler,
    QueueEventHandler, EventDispatchLogger {}

