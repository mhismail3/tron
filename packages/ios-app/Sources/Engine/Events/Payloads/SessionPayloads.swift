import Foundation

// MARK: - Session Lifecycle Payloads

/// Payload for session.fork event
/// Server: SessionForkEvent.payload
struct SessionForkPayload {
    let sourceSessionId: String
    let sourceEventId: String
    let name: String?
    let reason: String?

    init?(from payload: [String: AnyCodable]) {
        guard let sourceSessionId = payload.string("sourceSessionId"),
              let sourceEventId = payload.string("sourceEventId") else {
            return nil
        }
        self.sourceSessionId = sourceSessionId
        self.sourceEventId = sourceEventId
        self.name = payload.string("name")
        self.reason = payload.string("reason")
    }
}
