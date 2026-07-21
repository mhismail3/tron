import Foundation

// MARK: - Message Methods

struct MessageDeleteParams: Encodable {
    let sessionId: String
    let targetEventId: String
    let reason: String?

    init(sessionId: String, targetEventId: String, reason: String? = "user_request") {
        self.sessionId = sessionId
        self.targetEventId = targetEventId
        self.reason = reason
    }
}

struct MessageDeleteResult: Decodable {
    let success: Bool
    let deletionEventId: String
    let targetType: String
}
