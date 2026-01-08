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
        self.output = data["output"] as? String
        self.error = data["error"] as? String
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
    let stopReason: String?
    let durationMs: Int?

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

        self.stopReason = data["stopReason"] as? String
        self.durationMs = data["duration"] as? Int
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
