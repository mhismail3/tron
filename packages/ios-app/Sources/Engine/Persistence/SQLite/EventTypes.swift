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
    /// (no pending tool results, no unmatched tool_invocation blocks) are forkable.
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
    case sessionModelChanged = "session.model_changed"
    case sessionReasoningChanged = "session.reasoning_changed"
    case messageUser = "message.user"
    case messageAssistant = "message.assistant"

    case modelProviderRequest = "model.provider_request"

    case toolInvocationStarted = "tool.invocation.started"
    case toolInvocationCompleted = "tool.invocation.completed"

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
        .sessionModelChanged,
        .sessionReasoningChanged,
        .messageUser,
        .messageAssistant,
        .modelProviderRequest,
        .messageDeleted,
        .toolInvocationStarted,
        .toolInvocationCompleted,
        .streamTurnStart,
        .streamTurnEnd,
        .compactBoundary,
        .turnFailed
    ]
}
