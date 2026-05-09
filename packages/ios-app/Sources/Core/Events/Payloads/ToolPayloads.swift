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
    /// `session::reconstruct` enrichment: `toolStatus`,
    /// `confirmationDecision`, `confirmationNote`, `parsedAnswers`).
    let rawPayload: [String: AnyCodable]

    init?(from payload: [String: AnyCodable]) {
        // toolCallId can be "toolCallId" or "id".
        // `turn` is always emitted by `ToolCallPayload` on the server
        // (non-optional `i64`) — dropping the back-compat `?? 1` default
        // keeps reconstruction from silently pinning a stray event to turn 1.
        guard let id = payload.string("toolCallId") ?? payload.string("id"),
              let name = payload.string("name"),
              let turn = payload.int("turn") else {
            TronLogger.shared.warning(
                "tool.call event missing required field(s) toolCallId/name/turn; dropping",
                category: .events
            )
            return nil
        }

        self.toolCallId = id
        self.name = name
        self.turn = turn
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
        // `content`, `isError`, `duration` are all non-optional on the
        // server's `ToolResultPayload`. Empty string is a legitimate
        // `content` value (tools that return no text); missing the key
        // entirely is a schema violation.
        guard
            let toolCallId = payload.string("toolCallId"),
            let content = payload.string("content"),
            let isError = payload.bool("isError"),
            let durationMs = payload.int("duration")
        else {
            TronLogger.shared.warning(
                "tool.result event missing required field(s) toolCallId/content/isError/duration; dropping",
                category: .events
            )
            return nil
        }

        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.durationMs = durationMs
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
        // `recoverable` is non-optional on the server's `ErrorAgentPayload`.
        // Dropping the `?? false` default catches the case where a malformed
        // importer forgets to classify the error — we'd rather drop the
        // breadcrumb than silently mislabel it as unrecoverable.
        guard let error = payload.string("error")
                ?? payload.string("message"),
              let recoverable = payload.bool("recoverable") else {
            TronLogger.shared.warning(
                "error.agent event missing required field(s) error/recoverable; dropping",
                category: .events
            )
            return nil
        }

        self.error = error
        self.code = payload.string("code")
        self.recoverable = recoverable
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
/// (e.g. historical imported api_error records). Missing category → decode fails
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
        // `retryable` is non-optional on the server's `ErrorProviderPayload`.
        // Dropping the `?? false` default keeps a network-timeout event from
        // silently looking "non-retryable" to the UI just because the
        // emitter forgot the field.
        guard let provider = payload.string("provider"),
              let error = payload.string("error"),
              let category = payload.string("category"),
              let retryable = payload.bool("retryable") else {
            TronLogger.shared.warning(
                "error.provider event missing required field(s) provider/error/category/retryable; dropping",
                category: .events
            )
            return nil
        }

        self.provider = provider
        self.error = error
        self.code = payload.string("code")
        self.category = category
        self.suggestion = payload.string("suggestion")
        self.retryable = retryable
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
        // `turn` and `recoverable` are both non-optional on the server's
        // `TurnFailedPayload`. The server emits `turn: 0` for failures that
        // happened before a turn was assigned — a decoded `0` is meaningful,
        // a missing field is not.
        guard let error = payload.string("error")
                ?? payload.string("message"),
              let turn = payload.int("turn"),
              let recoverable = payload.bool("recoverable") else {
            TronLogger.shared.warning(
                "turn.failed event missing required field(s) error/turn/recoverable; dropping",
                category: .events
            )
            return nil
        }

        self.turn = turn
        self.error = error
        self.code = payload.string("code")
        self.category = payload.string("category")
        self.recoverable = recoverable
    }
}
