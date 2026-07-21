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

/// Event rows that can exist in the client cache.
///
/// `serverDurableCases` mirrors the Rust session log. The client also stores a
/// local `stream.thinking_complete` projection so expanded reasoning survives
/// app restarts; it is not a server event.
enum SessionEventType: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session.start"
    case sessionEnd = "session.end"
    case sessionFork = "session.fork"
    case messageUser = "message.user"
    case messageAssistant = "message.assistant"

    case modelProviderRequest = "model.provider_request"

    case capabilityInvocationStarted = "capability.invocation.started"
    case capabilityInvocationCompleted = "capability.invocation.completed"

    /// Client-local completed-thinking cache row.
    case streamThinkingComplete = "stream.thinking_complete"
    case streamTurnStart = "stream.turn_start"
    case streamTurnEnd = "stream.turn_end"

    case messageDeleted = "message.deleted"
    case compactBoundary = "compact.boundary"
    case turnFailed = "turn.failed"

    case unknown

    static let serverDurableCases: [SessionEventType] = [
        .sessionStart,
        .sessionEnd,
        .sessionFork,
        .messageUser,
        .messageAssistant,
        .modelProviderRequest,
        .messageDeleted,
        .capabilityInvocationStarted,
        .capabilityInvocationCompleted,
        .streamTurnStart,
        .streamTurnEnd,
        .compactBoundary,
        .turnFailed
    ]
}

// MARK: - Sync State

/// Tracks synchronization state with server
struct SyncState: Codable, Sendable {
    let key: String
    var lastSyncedEventId: String?
    var lastSyncTimestamp: String?
    var pendingEventIds: [String]
}
