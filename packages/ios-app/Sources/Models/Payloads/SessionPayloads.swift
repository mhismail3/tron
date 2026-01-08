import Foundation

// MARK: - Session Lifecycle Payloads

/// Payload for session.start event
/// Server: SessionStartEvent.payload
struct SessionStartPayload {
    let workingDirectory: String
    let model: String
    let provider: String
    let systemPrompt: String?
    let title: String?
    let tags: [String]?
    let forkedFrom: ForkedFromInfo?

    struct ForkedFromInfo {
        let sessionId: String
        let eventId: String
    }

    init(from payload: [String: AnyCodable]) {
        self.workingDirectory = payload.string("workingDirectory") ?? ""
        self.model = payload.string("model") ?? ""
        self.provider = payload.string("provider") ?? ""
        self.systemPrompt = payload.string("systemPrompt")
        self.title = payload.string("title")
        self.tags = payload.stringArray("tags")

        if let forked = payload.dict("forkedFrom") {
            self.forkedFrom = ForkedFromInfo(
                sessionId: forked["sessionId"] as? String ?? "",
                eventId: forked["eventId"] as? String ?? ""
            )
        } else {
            self.forkedFrom = nil
        }
    }
}

/// Payload for session.end event
/// Server: SessionEndEvent.payload
struct SessionEndPayload {
    let reason: SessionEndReason?
    let summary: String?
    let totalTokenUsage: TokenUsage?
    let duration: Int?  // milliseconds

    init(from payload: [String: AnyCodable]) {
        if let reasonStr = payload.string("reason") {
            self.reason = SessionEndReason(rawValue: reasonStr)
        } else {
            self.reason = nil
        }
        self.summary = payload.string("summary")
        self.duration = payload.int("duration")

        if let usage = payload.dict("totalTokenUsage") {
            self.totalTokenUsage = TokenUsage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.totalTokenUsage = nil
        }
    }
}

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

/// Payload for session.branch event
/// Server: SessionBranchEvent.payload
struct SessionBranchPayload {
    let branchId: String
    let name: String
    let description: String?

    init?(from payload: [String: AnyCodable]) {
        guard let branchId = payload.string("branchId"),
              let name = payload.string("name") else {
            return nil
        }
        self.branchId = branchId
        self.name = name
        self.description = payload.string("description")
    }
}
