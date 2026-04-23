import Foundation

// MARK: - Persisted Event Payloads
//
// These payloads parse persisted events from SQLite database.
// They extract data from [String: AnyCodable] dictionaries stored in event payloads.
//
// Note: Live WebSocket events use the plugin system in Core/Events/Plugins/ with EventRegistry.

/// Payload for stream.turn_end persisted event
/// Used to extract token usage from turn end events stored in SQLite
struct StreamTurnEndPayload {
    let turn: Int
    let tokenRecord: TokenRecord?

    /// Failable decode from a persisted `stream.turn_end` payload.
    ///
    /// `turn` is always emitted by the server; silently defaulting to 1
    /// used to pin `state.currentTurn` at 1 forever when the field went
    /// missing — a schema-drift symptom that was invisible in the UI.
    init?(from payload: [String: AnyCodable]) {
        guard let turn = payload.int("turn") else {
            TronLogger.shared.warning(
                "stream.turn_end event missing required `turn` field; dropping",
                category: .events
            )
            return nil
        }
        self.turn = turn
        self.tokenRecord = TokenRecord.from(dict: payload.dict("tokenRecord"))
    }

    /// Get the context window token count from tokenRecord
    var contextWindowTokens: Int {
        tokenRecord?.computed.contextWindowTokens ?? 0
    }

    /// Get the new input tokens for this turn (delta for stats line display)
    var newInputTokens: Int? {
        tokenRecord?.computed.newInputTokens
    }

    /// Get the output tokens for this turn
    var outputTokens: Int {
        tokenRecord?.source.rawOutputTokens ?? 0
    }
}

// MARK: - Thinking Complete Payload (persisted at turn end)

/// Payload for stream.thinking_complete event
/// Persisted to DB at turn end, contains consolidated thinking from a turn
struct ThinkingCompletePayload: Codable {
    let turnNumber: Int
    let content: String
    let preview: String
    let characterCount: Int
    let model: String?
    let timestamp: Date

    init(turnNumber: Int, content: String, model: String?, timestamp: Date = Date()) {
        self.turnNumber = turnNumber
        self.content = content
        self.characterCount = content.count
        self.model = model
        self.timestamp = timestamp

        // Extract first 3 lines for preview
        self.preview = ThinkingCompletePayload.extractPreview(from: content)
    }

    /// Failable decode from a persisted `stream.thinking_complete` payload.
    ///
    /// `turnNumber` and `content` are required. `characterCount` is always
    /// derived from `content`, so we recompute it rather than trusting a
    /// possibly-stale wire value — which also removes a mismatch hazard
    /// where content and characterCount disagreed after the decoder
    /// silently defaulted one but not the other.
    init?(from payload: [String: AnyCodable]) {
        guard
            let turnNumber = payload.int("turnNumber"),
            let content = payload.string("content")
        else {
            TronLogger.shared.warning(
                "stream.thinking_complete event missing required field(s) turnNumber/content; dropping",
                category: .events
            )
            return nil
        }
        self.turnNumber = turnNumber
        self.content = content
        self.preview = payload.string("preview")
            ?? ThinkingCompletePayload.extractPreview(from: content)
        self.characterCount = content.count
        self.model = payload.string("model")

        if let timestampStr = payload.string("timestamp") {
            self.timestamp = DateParser.parseOrNow(timestampStr)
        } else {
            self.timestamp = Date()
        }
    }

    /// Extract first 3 lines from content for caption preview
    private static func extractPreview(from content: String, maxLines: Int = 3) -> String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxLines)

        let preview = lines.joined(separator: " ")
        return preview.truncated(to: 200)
    }

    /// Convert to dictionary for DB persistence
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "turnNumber": turnNumber,
            "content": content,
            "preview": preview,
            "characterCount": characterCount,
            "timestamp": DateParser.toISO8601(timestamp)
        ]
        if let model = model {
            dict["model"] = model
        }
        return dict
    }
}
