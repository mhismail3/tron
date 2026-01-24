import Foundation

// MARK: - Stream Payloads (persisted streaming events)

/// Payload for stream.turn_end event
/// Server: StreamTurnEndEvent.payload
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

// MARK: - Streaming RPC Event Payloads (from server core/src/rpc/types.ts)

// These payload structures EXACTLY mirror the server's RPC event data types.
// Each struct corresponds to a specific StreamingEventType.

/// Payload for agent.text_delta event
/// Server: AgentTextDeltaEvent
struct StreamingTextDeltaPayload {
    let delta: String
    let accumulated: String?

    init?(from data: [String: Any]) {
        guard let delta = data["delta"] as? String else { return nil }
        self.delta = delta
        self.accumulated = data["accumulated"] as? String
    }
}

/// Payload for agent.thinking_delta event
/// Server: AgentThinkingDeltaEvent
struct StreamingThinkingDeltaPayload {
    let delta: String

    init?(from data: [String: Any]) {
        guard let delta = data["delta"] as? String else { return nil }
        self.delta = delta
    }
}

/// Payload for agent.tool_start event
/// Server: AgentToolStartEvent
struct StreamingToolStartPayload {
    let toolCallId: String
    let toolName: String
    let arguments: String  // JSON string

    init?(from data: [String: Any]) {
        guard let toolCallId = data["toolCallId"] as? String,
              let toolName = data["toolName"] as? String else { return nil }

        self.toolCallId = toolCallId
        self.toolName = toolName

        if let argsDict = data["arguments"] as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else {
            self.arguments = "{}"
        }
    }
}

/// Payload for agent.tool_end event
/// Server: AgentToolEndEvent
struct StreamingToolEndPayload {
    let toolCallId: String
    let toolName: String
    let durationMs: Int
    let success: Bool
    let output: String?
    let error: String?

    init?(from data: [String: Any]) {
        guard let toolCallId = data["toolCallId"] as? String,
              let toolName = data["toolName"] as? String else { return nil }

        self.toolCallId = toolCallId
        self.toolName = toolName
        self.durationMs = data["duration"] as? Int ?? 0
        self.success = data["success"] as? Bool ?? true
        self.error = data["error"] as? String

        // Handle output as either String or array of content blocks
        // Server may send: "output": "text" OR "output": [{"type":"text","text":"..."}]
        if let outputString = data["output"] as? String {
            self.output = outputString
        } else if let outputArray = data["output"] as? [[String: Any]] {
            // Extract text from content blocks and join them
            self.output = outputArray.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }.joined()
        } else {
            self.output = nil
        }
    }
}

/// Payload for agent.turn_start event
struct StreamingTurnStartPayload {
    let turn: Int

    init?(from data: [String: Any]) {
        guard let turn = data["turn"] as? Int ?? data["turnNumber"] as? Int else { return nil }
        self.turn = turn
    }
}

/// Payload for agent.turn_end event
struct StreamingTurnEndPayload {
    let turn: Int
    let tokenUsage: TokenUsage?
    /// Server-calculated normalized token usage (preferred over local calculations)
    let normalizedUsage: NormalizedTokenUsage?
    let stopReason: String?
    let durationMs: Int?
    /// Current model's context window limit (for syncing iOS state after model switch)
    let contextLimit: Int?

    init?(from data: [String: Any]) {
        guard let turn = data["turn"] as? Int ?? data["turnNumber"] as? Int else { return nil }
        self.turn = turn

        if let usage = data["tokenUsage"] as? [String: Any] {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["input"] as? Int ?? usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["output"] as? Int ?? usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }

        // Parse normalizedUsage from server
        if let normalized = data["normalizedUsage"] as? [String: Any] {
            self.normalizedUsage = NormalizedTokenUsage(
                newInputTokens: normalized["newInputTokens"] as? Int ?? 0,
                outputTokens: normalized["outputTokens"] as? Int ?? 0,
                contextWindowTokens: normalized["contextWindowTokens"] as? Int ?? 0,
                rawInputTokens: normalized["rawInputTokens"] as? Int ?? 0,
                cacheReadTokens: normalized["cacheReadTokens"] as? Int ?? 0,
                cacheCreationTokens: normalized["cacheCreationTokens"] as? Int ?? 0
            )
        } else {
            self.normalizedUsage = nil
        }

        self.stopReason = data["stopReason"] as? String
        self.durationMs = data["duration"] as? Int
        self.contextLimit = data["contextLimit"] as? Int
    }
}

/// Payload for agent.complete event
/// Server: AgentCompleteEvent
struct StreamingCompletePayload {
    let turns: Int
    let tokenUsage: TokenUsage?
    let success: Bool
    let error: String?

    init?(from data: [String: Any]) {
        self.turns = data["turns"] as? Int ?? 0
        self.success = data["success"] as? Bool ?? true
        self.error = data["error"] as? String

        if let usage = data["tokenUsage"] as? [String: Any] {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["input"] as? Int ?? usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["output"] as? Int ?? usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }
    }
}

/// Payload for agent.error event
struct StreamingErrorPayload {
    let code: String?
    let message: String
    let error: String?

    init?(from data: [String: Any]) {
        guard let message = data["message"] as? String ?? data["error"] as? String else {
            return nil
        }
        self.message = message
        self.code = data["code"] as? String
        self.error = data["error"] as? String
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
