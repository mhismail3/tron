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
struct SessionEvent: Identifiable, Codable, EventTransformable {
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
        case .messageUser:
            return true
        case .messageAssistant:
            return !contentHasToolUse
        default:
            return false
        }
    }

    /// Whether this assistant message's content contains tool_use blocks.
    /// Mirrors the Rust `content_has_tool_use` function in reconstruct.rs.
    private var contentHasToolUse: Bool {
        // Fast path: stopReason explicitly indicates tool use
        if payload.string("stopReason") == "tool_use" {
            return true
        }
        // Check content array for tool_use blocks (handles interrupted messages
        // where stopReason may be "interrupted" but content still has tool_use)
        guard let contentArray = payload["content"]?.value as? [[String: Any]] else {
            return false
        }
        return contentArray.contains { ($0["type"] as? String) == "tool_use" }
    }
}

/// Known session event types
enum SessionEventType: String, Codable {
    case sessionStart = "session.start"
    case sessionEnd = "session.end"
    case sessionFork = "session.fork"
    case sessionBranch = "session.branch"

    case messageUser = "message.user"
    case messageAssistant = "message.assistant"
    case messageSystem = "message.system"

    case toolCall = "tool.call"
    case toolResult = "tool.result"

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
    case skillAdded = "skill.added"
    case skillRemoved = "skill.removed"

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
    case errorTool = "error.tool"
    case errorProvider = "error.provider"

    // Worktree
    case worktreeAcquired = "worktree.acquired"
    case worktreeCommit = "worktree.commit"
    case worktreeReleased = "worktree.released"
    case worktreeMerged = "worktree.merged"
    case worktreeRenamed = "worktree.renamed"

    // Process management
    case notificationProcessResult = "notification.process_result"
    case processResultsConsumed = "process.results_consumed"

    case unknown
}

// MARK: - Sync State

/// Tracks synchronization state with server
struct SyncState: Codable {
    let key: String
    var lastSyncedEventId: String?
    var lastSyncTimestamp: String?
    var pendingEventIds: [String]
}

// MARK: - Tree Node

/// Node for tree visualization
struct EventTreeNode: Identifiable {
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

// MARK: - Session State
// NOTE: Legacy types (ReconstructedSessionState, ReconstructedMessage)
// have been removed. Use ReconstructedState from Core/Events/Transformer/Reconstruction/.
