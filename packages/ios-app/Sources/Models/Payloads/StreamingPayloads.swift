import Foundation

// MARK: - Persisted Event Payloads
//
// These payloads parse persisted events from SQLite database.
// They extract data from [String: AnyCodable] dictionaries stored in event payloads.
//
// Note: Live WebSocket events use the Decodable types in Events.swift with ParsedEvent.parse().

/// Payload for stream.turn_end persisted event
/// Used to extract token usage from turn end events stored in SQLite
struct StreamTurnEndPayload {
    let turn: Int
    let tokenUsage: TokenUsage?

    init(from payload: [String: AnyCodable]) {
        self.turn = payload.int("turn") ?? 1

        if let usage = payload.dict("tokenUsage") {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }
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
