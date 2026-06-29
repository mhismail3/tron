import Foundation

/// Plugin for session fork markers.
///
/// The session list reconciles through `session.created` / `session.updated`
/// snapshots. This marker is parsed for event-surface completeness only.
enum SessionForkedPlugin: EventPlugin {
    static let eventType = "session.forked"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
