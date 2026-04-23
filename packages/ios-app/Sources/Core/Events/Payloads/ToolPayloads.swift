import Foundation

// MARK: - Tool Payloads

/// Payload for tool.call event
/// Server: ToolCallEvent.payload
struct ToolCallPayload {
    let toolCallId: String
    let name: String
    let arguments: String  // JSON string for display
    let turn: Int
    /// Full payload dict preserved so transformers can access
    /// server-enriched fields (e.g. interactive tool status from
    /// `session.reconstruct` enrichment: `toolStatus`,
    /// `confirmationDecision`, `confirmationNote`, `parsedAnswers`).
    let rawPayload: [String: AnyCodable]

    init?(from payload: [String: AnyCodable]) {
        // toolCallId can be "toolCallId" or "id"
        guard let id = payload.string("toolCallId") ?? payload.string("id"),
              let name = payload.string("name") else {
            return nil
        }

        self.toolCallId = id
        self.name = name
        self.turn = payload.int("turn") ?? 1
        self.rawPayload = payload

        // Arguments can be dict or string
        if let argsDict = payload.dict("arguments"),
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else if let argsStr = payload.string("arguments") {
            self.arguments = argsStr
        } else {
            self.arguments = "{}"
        }
    }
}

/// Payload for tool.result event
/// Server: ToolResultEvent.payload
struct ToolResultPayload {
    let toolCallId: String
    let content: String
    let isError: Bool
    let durationMs: Int
    let affectedFiles: [String]?
    let truncated: Bool?
    /// Blob ID if content was stored in blob storage (for large results)
    let blobId: String?

    // Additional fields for display (may come from enrichment)
    let name: String?
    let arguments: String?
    /// Tool-specific structured metadata (e.g. WebFetch: url, status, fromCache, responseHeaders).
    let details: [String: AnyCodable]?

    init?(from payload: [String: AnyCodable]) {
        guard let toolCallId = payload.string("toolCallId") else {
            return nil
        }

        self.toolCallId = toolCallId
        self.content = payload.string("content") ?? ""
        self.isError = payload.bool("isError") ?? false
        self.durationMs = payload.int("duration") ?? 0
        self.affectedFiles = payload.stringArray("affectedFiles")
        self.truncated = payload.bool("truncated")
        self.blobId = payload.string("blobId")

        // Optional enrichment fields
        self.name = payload.string("name")
        if let argsDict = payload.dict("arguments"),
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else if let argsStr = payload.string("arguments") {
            self.arguments = argsStr
        } else {
            self.arguments = nil
        }

        // Tool-specific details (new field persisted by Rust agent)
        if let detailsValue = payload["details"],
           let detailsDict = detailsValue.value as? [String: Any] {
            self.details = detailsDict.mapValues { AnyCodable($0) }
        } else {
            self.details = nil
        }
    }

}

// MARK: - Error Payloads

/// Payload for error.agent event
/// Server: ErrorAgentEvent.payload
struct AgentErrorPayload {
    let error: String
    let code: String?
    let recoverable: Bool

    init?(from payload: [String: AnyCodable]) {
        guard let error = payload.string("error")
                ?? payload.string("message") else {
            return nil
        }

        self.error = error
        self.code = payload.string("code")
        self.recoverable = payload.bool("recoverable") ?? false
    }
}

/// Payload for error.tool event
/// Server: ErrorToolEvent.payload
struct ToolErrorPayload {
    let toolName: String
    let toolCallId: String
    let error: String
    let code: String?

    init?(from payload: [String: AnyCodable]) {
        guard let toolName = payload.string("toolName"),
              let toolCallId = payload.string("toolCallId"),
              let error = payload.string("error") else {
            return nil
        }

        self.toolName = toolName
        self.toolCallId = toolCallId
        self.error = error
        self.code = payload.string("code")
    }
}

/// Payload for error.provider event
/// Server: ErrorProviderEvent.payload
///
/// `category` is REQUIRED. The Rust schema is `deny_unknown_fields` and emits
/// `"unknown"` literally when the classification layer couldn't narrow further
/// (e.g. legacy imported api_error records). Missing category → decode fails
/// → event is dropped from reconstruction, never silently rendered as
/// plain text.
struct ProviderErrorPayload {
    let provider: String
    let error: String
    let code: String?
    let category: String
    let suggestion: String?
    let retryable: Bool
    let retryAfter: Int?
    let statusCode: Int?
    let errorType: String?
    let model: String?

    init?(from payload: [String: AnyCodable]) {
        guard let provider = payload.string("provider"),
              let error = payload.string("error"),
              let category = payload.string("category") else {
            return nil
        }

        self.provider = provider
        self.error = error
        self.code = payload.string("code")
        self.category = category
        self.suggestion = payload.string("suggestion")
        self.retryable = payload.bool("retryable") ?? false
        self.retryAfter = payload.int("retryAfter")
        self.statusCode = payload.int("statusCode")
        self.errorType = payload.string("errorType")
        self.model = payload.string("model")
    }
}

/// Payload for turn.failed event
/// Server: TurnFailedEvent.payload
struct TurnFailedPayload {
    let turn: Int
    let error: String
    let code: String?
    let category: String?
    let recoverable: Bool

    init?(from payload: [String: AnyCodable]) {
        guard let error = payload.string("error")
                ?? payload.string("message") else {
            return nil
        }

        self.turn = payload.int("turn") ?? 0
        self.error = error
        self.code = payload.string("code")
        self.category = payload.string("category")
        self.recoverable = payload.bool("recoverable") ?? false
    }
}
