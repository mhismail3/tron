import Foundation

/// Plugin for handling session.deleted events.
/// These events indicate a session was permanently deleted on another device.
enum SessionDeletedPlugin: EventPlugin {
    static let eventType = "session.deleted"

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
