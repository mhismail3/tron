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

    init(from payload: [String: AnyCodable]) {
        self.turn = payload.int("turn") ?? 1

        // Extract tokenRecord for accurate context tracking
        if let record = payload.dict("tokenRecord"),
           let sourceDict = record["source"] as? [String: Any],
           let computedDict = record["computed"] as? [String: Any],
           let metaDict = record["meta"] as? [String: Any] {
            let source = TokenSource(
                provider: sourceDict["provider"] as? String ?? "",
                timestamp: sourceDict["timestamp"] as? String ?? "",
                rawInputTokens: sourceDict["rawInputTokens"] as? Int ?? 0,
                rawOutputTokens: sourceDict["rawOutputTokens"] as? Int ?? 0,
                rawCacheReadTokens: sourceDict["rawCacheReadTokens"] as? Int ?? 0,
                rawCacheCreationTokens: sourceDict["rawCacheCreationTokens"] as? Int ?? 0
            )
            let computed = ComputedTokens(
                contextWindowTokens: computedDict["contextWindowTokens"] as? Int ?? 0,
                newInputTokens: computedDict["newInputTokens"] as? Int ?? 0,
                previousContextBaseline: computedDict["previousContextBaseline"] as? Int ?? 0,
                calculationMethod: computedDict["calculationMethod"] as? String ?? ""
            )
            let meta = TokenMeta(
                turn: metaDict["turn"] as? Int ?? 1,
                sessionId: metaDict["sessionId"] as? String ?? "",
                extractedAt: metaDict["extractedAt"] as? String ?? "",
                normalizedAt: metaDict["normalizedAt"] as? String ?? ""
            )
            self.tokenRecord = TokenRecord(source: source, computed: computed, meta: meta)
        } else {
            self.tokenRecord = nil
        }
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

    init(from payload: [String: AnyCodable]) {
        self.turnNumber = payload.int("turnNumber") ?? 1
        self.content = payload.string("content") ?? ""
        self.preview = payload.string("preview") ?? ""
        self.characterCount = payload.int("characterCount") ?? 0
        self.model = payload.string("model")

        // Parse timestamp from ISO8601 string
        if let timestampStr = payload.string("timestamp") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.timestamp = formatter.date(from: timestampStr) ?? Date()
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
        if preview.count > 200 {
            return String(preview.prefix(197)) + "..."
        }
        return preview
    }

    /// Convert to dictionary for DB persistence
    func toDictionary() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var dict: [String: Any] = [
            "turnNumber": turnNumber,
            "content": content,
            "preview": preview,
            "characterCount": characterCount,
            "timestamp": formatter.string(from: timestamp)
        ]
        if let model = model {
            dict["model"] = model
        }
        return dict
    }
}
