import Foundation

/// Protocol unifying `RawEvent` and `SessionEvent` for generic transformation.
///
/// Both `RawEvent` (from server RPC) and `SessionEvent` (from SQLite database)
/// have identical fields representing the same event structure. This protocol
/// eliminates ~460 LOC of duplication by enabling a single generic implementation
/// for event transformation logic.
///
/// ## Conformance
/// Both types conform trivially since they already have all required fields:
/// ```swift
/// extension RawEvent: EventTransformable {}
/// extension SessionEvent: EventTransformable {}
/// ```
///
/// ## Usage
/// Generic functions can now work with either type:
/// ```swift
/// func transformEvents<E: EventTransformable>(_ events: [E]) -> [ChatMessage]
/// ```
protocol EventTransformable {
    /// Unique identifier for this event
    var id: String { get }

    /// Parent event ID (for tree structure)
    var parentId: String? { get }

    /// Session this event belongs to
    var sessionId: String { get }

    /// Workspace this event belongs to
    var workspaceId: String { get }

    /// Event type (e.g., "message.user", "tool.call")
    var type: String { get }

    /// ISO 8601 timestamp when event occurred
    var timestamp: String { get }

    /// Sequence number for ordering within session
    var sequence: Int { get }

    /// Event-specific payload data
    var payload: [String: AnyCodable] { get }
}
