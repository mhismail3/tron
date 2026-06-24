import Foundation

/// Plugin for handling session.archived events.
/// These events indicate a session was archived (soft-deleted) on another device.
enum SessionArchivedPlugin: EventPlugin {
    static let eventType = "session.archived"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sessionId: String?
        }
    }

    struct Result: EventResult {
        let sessionId: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let sid = event.sessionId ?? event.data?.sessionId else { return nil }
        return Result(sessionId: sid)
    }
}
