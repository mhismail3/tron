import Foundation

/// Type-erased wrapper for parsed event data.
/// Using @unchecked Sendable because the actual event data types are Sendable,
/// but Swift's type system cannot verify this through the type-erased `Any`.
struct ParsedEventData: @unchecked Sendable {
    let value: Any
}

/// Unified event wrapper for the plugin-based event system.
/// All WebSocket events are parsed through EventRegistry and wrapped in this enum.
/// Using @unchecked Sendable because the stored event data and transform closure
/// are guaranteed to be Sendable by the EventPlugin protocol requirements.
enum ParsedEventV2: @unchecked Sendable {
    /// Successfully parsed event from a registered plugin.
    /// - type: The event type string (e.g., "agent.text_delta")
    /// - event: The parsed event data (type-erased wrapper)
    /// - sessionId: Extracted session ID for filtering
    /// - transform: Lazy transformation closure to get EventResult
    case plugin(type: String, event: ParsedEventData, sessionId: String?, transform: @Sendable () -> (any EventResult)?)

    /// Unknown event type (not registered in EventRegistry).
    case unknown(String)

    // MARK: - Accessors

    /// The event type string.
    var eventType: String {
        switch self {
        case .plugin(let type, _, _, _): return type
        case .unknown(let type): return type
        }
    }

    /// Extract sessionId from the event for filtering.
    /// Returns nil for events that don't have a sessionId (e.g., connected, unknown).
    var sessionId: String? {
        switch self {
        case .plugin(_, _, let sessionId, _): return sessionId
        case .unknown: return nil
        }
    }

    /// Check if this event matches the given session ID.
    /// Returns true if the event has no sessionId (global event) or if it matches.
    func matchesSession(_ targetSessionId: String?) -> Bool {
        guard let eventSessionId = sessionId else { return true }
        guard let targetSessionId = targetSessionId else { return false }
        return eventSessionId == targetSessionId
    }

    /// Get the transformed result, if available.
    func getResult() -> (any EventResult)? {
        switch self {
        case .plugin(_, _, _, let transform): return transform()
        case .unknown: return nil
        }
    }

    /// Get the raw event data (type-erased).
    func getEvent<T>() -> T? {
        switch self {
        case .plugin(_, let event, _, _): return event.value as? T
        case .unknown: return nil
        }
    }
}
