import Foundation

// MARK: - Message Payloads

/// Payload for message.user event
/// Server: UserMessageEvent.payload
struct UserMessagePayload {
    let content: String
    let turn: Int
    let imageCount: Int?

    init?(from payload: [String: AnyCodable]) {
        // Content can be a string or array of content blocks
        if let content = payload.string("content") {
            self.content = content
        } else if let contentBlocks = payload["content"]?.value as? [[String: Any]] {
            // Extract text from content blocks
            let texts = contentBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            self.content = texts.joined(separator: "\n")
        } else {
            return nil
        }

        self.turn = payload.int("turn") ?? 1
        self.imageCount = payload.int("imageCount")
    }
}

/// Payload for message.assistant event
/// Server: AssistantMessageEvent.payload
///
/// IMPORTANT: This payload contains ContentBlocks which may include tool_use blocks.
/// However, tool_use blocks should be IGNORED here - they are rendered via tool.call events.
struct AssistantMessagePayload {
    let contentBlocks: [[String: Any]]?
    let turn: Int
    let tokenUsage: TokenUsage?
    let stopReason: StopReason?
    let latencyMs: Int?
    let model: String?
    let hasThinking: Bool?
    let interrupted: Bool?

    /// Extracts ONLY the text content, ignoring tool_use blocks
    /// Tool calls are rendered via separate tool.call events
    var textContent: String? {
        guard let blocks = contentBlocks else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Extracts thinking content if present
    var thinkingContent: String? {
        guard let blocks = contentBlocks else { return nil }
        let thoughts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "thinking" else { return nil }
            return block["thinking"] as? String
        }
        return thoughts.isEmpty ? nil : thoughts.joined(separator: "\n")
    }

    init(from payload: [String: AnyCodable]) {
        // Content can be array of blocks or direct string (legacy)
        if let blocks = payload["content"]?.value as? [[String: Any]] {
            self.contentBlocks = blocks
        } else if let text = payload.string("content") {
            // Legacy: convert string to text block
            self.contentBlocks = [["type": "text", "text": text]]
        } else if let text = payload.string("text") {
            // Alternative field name
            self.contentBlocks = [["type": "text", "text": text]]
        } else {
            self.contentBlocks = nil
        }

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

        if let stopStr = payload.string("stopReason") {
            self.stopReason = StopReason(rawValue: stopStr)
        } else {
            self.stopReason = nil
        }

        self.latencyMs = payload.int("latency") ?? payload.int("latencyMs")
        self.model = payload.string("model")
        self.hasThinking = payload.bool("hasThinking")
        self.interrupted = payload.bool("interrupted")
    }
}

/// Payload for message.system event
/// Server: SystemMessageEvent.payload
struct SystemMessagePayload {
    let content: String
    let source: SystemMessageSource?

    init?(from payload: [String: AnyCodable]) {
        guard let content = payload.string("content") else {
            return nil
        }
        self.content = content

        if let sourceStr = payload.string("source") {
            self.source = SystemMessageSource(rawValue: sourceStr)
        } else {
            self.source = nil
        }
    }
}
