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

    /// Failable decode from a persisted `session.start` payload.
    ///
    /// `workingDirectory`, `model`, and `provider` are required — the server
    /// always emits them and the UI relies on them for routing/display.
    /// A missing field silently defaulting to "" used to paper over schema
    /// drift and leave the UI showing a blank session; instead we now refuse
    /// to decode and drop the event with a log entry.
    init?(from payload: [String: AnyCodable]) {
        guard
            let workingDirectory = payload.string("workingDirectory"),
            let model = payload.string("model"),
            let provider = payload.string("provider")
        else {
            TronLogger.shared.warning(
                "session.start event missing required field(s) workingDirectory/model/provider; dropping",
                category: .events
            )
            return nil
        }

        self.workingDirectory = workingDirectory
        self.model = model
        self.provider = provider
        self.systemPrompt = payload.string("systemPrompt")
        self.title = payload.string("title")
        self.tags = payload.stringArray("tags")

        if let forked = payload.dict("forkedFrom") {
            guard
                let sessionId = forked["sessionId"] as? String,
                let eventId = forked["eventId"] as? String
            else {
                TronLogger.shared.warning(
                    "session.start forkedFrom missing sessionId/eventId; dropping fork info",
                    category: .events
                )
                self.forkedFrom = nil
                return
            }
            self.forkedFrom = ForkedFromInfo(sessionId: sessionId, eventId: eventId)
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
