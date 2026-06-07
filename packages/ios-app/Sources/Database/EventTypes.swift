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
    /// (no pending capability results, no unmatched capability_invocation blocks) are forkable.
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

    case compactBoundary = "compact.boundary"

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

    // Turn events
    case turnFailed = "turn.failed"

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
