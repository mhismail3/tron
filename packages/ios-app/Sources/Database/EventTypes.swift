import Foundation

// MARK: - Event Store Types

/// Unique identifier for events (branded type pattern)
struct EventId: Hashable, Codable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

/// Unique identifier for sessions (branded type pattern)
struct SessionId: Hashable, Codable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

/// Unique identifier for workspaces (branded type pattern)
struct WorkspaceId: Hashable, Codable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

// MARK: - Session Event

/// A single event in the event-sourced session tree
struct SessionEvent: Identifiable, Codable, EventTransformable, Sendable {
    let id: String
    let parentId: String?
    let sessionId: String
    let workspaceId: String
    let type: String
    let timestamp: String
    let sequence: Int
    let payload: [String: AnyCodable]

    /// Event type enumeration
    var eventType: SessionEventType {
        SessionEventType(rawValue: type) ?? .unknown
    }

    // MARK: - Fork Safety

    /// Whether this event is a safe fork point for session branching.
    ///
    /// Only events where the message reconstruction state is consistent
    /// (no pending tool results, no unmatched tool_use blocks) are forkable.
    /// Mirrors the invariants in the Rust `build_messages` function in reconstruct.rs.
    var isForkable: Bool {
        switch eventType {
        case .messageUser, .messageAssistant:
            return true
        default:
            return false
        }
    }
}

/// Known session event types
enum SessionEventType: String, Codable, Sendable {
    case sessionStart = "session.start"
    case sessionEnd = "session.end"
    case sessionFork = "session.fork"
    case sessionBranch = "session.branch"

    case messageUser = "message.user"
    case messageAssistant = "message.assistant"
    case messageSystem = "message.system"

    case capabilityInvocationStarted = "capability.invocation.started"
    case capabilityInvocationCompleted = "capability.invocation.completed"

    case streamTextDelta = "stream.text_delta"
    case streamThinkingDelta = "stream.thinking_delta"
    case streamThinkingComplete = "stream.thinking_complete"
    case streamTurnStart = "stream.turn_start"
    case streamTurnEnd = "stream.turn_end"

    case configModelSwitch = "config.model_switch"
    case configPromptUpdate = "config.prompt_update"
    case configReasoningLevel = "config.reasoning_level"

    // Message operations
    case messageDeleted = "message.deleted"

    // Notifications (in-chat pill notifications)
    case notificationInterrupted = "notification.interrupted"

    // Skills
    case skillActivated = "skills::activated"
    case skillDeactivated = "skills::deactivated"
    case skillsCleared = "skills.cleared"

    case compactBoundary = "compact.boundary"
    case compactSummary = "compact.summary"

    // Rules tracking
    case rulesLoaded = "rules.loaded"
    case rulesActivated = "rules.activated"

    // Context
    case contextCleared = "context.cleared"

    case metadataUpdate = "metadata.update"
    case metadataTag = "metadata.tag"

    case fileRead = "file.read"
    case fileWrite = "file.write"
    case fileEdit = "file.edit"

    case errorAgent = "error.agent"
    case errorCapability = "error.capability"
    case errorProvider = "error.provider"

    // Worktree
    case worktreeAcquired = "worktree.acquired"
    case worktreeCommit = "worktree.commit"
    case worktreeReleased = "worktree.released"
    case worktreeMerged = "worktree.merged"
    case worktreeRenamed = "worktree.renamed"

    // Subagent lifecycle
    case subagentSpawned = "subagent.spawned"
    case subagentCompleted = "subagent.completed"
    case subagentFailed = "subagent.failed"
    case subagentResultsConsumed = "subagent.results_consumed"

    // Notifications
    case notificationSubagentResult = "notification.subagent_result"

    // Process management
    case notificationProcessResult = "notification.process_result"
    case processResultsConsumed = "process.results_consumed"

    // Turn events
    case turnFailed = "turn.failed"

    // Memory
    case memoryRetained = "memory.retained"
    case memoryAutoRetainTriggered = "memory.auto_retain_triggered"
    case memoryAutoRetainFailed = "memory.auto_retain_failed"

    // Hooks
    case llmHookResult = "hook.llm_result"

    case unknown
}

// MARK: - Sync State

/// Tracks synchronization state with server
struct SyncState: Codable, Sendable {
    let key: String
    var lastSyncedEventId: String?
    var lastSyncTimestamp: String?
    var pendingEventIds: [String]
}

// MARK: - Tree Node

/// Node for tree visualization
struct EventTreeNode: Identifiable, Sendable {
    let id: String
    let parentId: String?
    let type: String
    let timestamp: String
    let summary: String
    let hasChildren: Bool
    let childCount: Int
    let depth: Int
    let isBranchPoint: Bool
    let isHead: Bool
}
