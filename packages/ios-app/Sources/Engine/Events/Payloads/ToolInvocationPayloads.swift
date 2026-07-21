import Foundation

// MARK: - Tool Invocation Payloads

/// Payload for tool.invocation.started event
struct ToolInvocationStartedPayload {
    let invocationId: String
    let toolName: String
    let arguments: String  // JSON string for display
    let turn: Int
    let identity: ToolIdentity
    /// Full payload dict preserved so transformers can access primitive trace
    /// and presentation metadata.
    let rawPayload: [String: AnyCodable]

    init?(from payload: [String: AnyCodable]) {
        // invocationId can be "invocationId" or "id".
        // `turn` is required; missing turn data makes the event invalid.
        guard let id = payload.string("invocationId") ?? payload.string("id"),
              let toolName = payload.string("toolName"),
              let turn = payload.int("turn") else {
            TronLogger.shared.warning(
                "tool.invocation.started event missing required field(s) invocationId/toolName/turn; dropping",
                category: .events
            )
            return nil
        }

        self.invocationId = id
        self.toolName = toolName
        self.turn = turn
        self.rawPayload = payload
        self.identity = ToolIdentity(
            toolName: toolName,
            traceId: payload.string("traceId"),
            rootInvocationId: payload.string("rootInvocationId"),
            themeColor: payload.string("themeColor"),
            presentationHints: payload.dict("presentationHints")?.mapValues { AnyCodable($0) }
        )

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

    var name: String { toolName }
}

/// Payload for tool.invocation.completed event
struct ToolInvocationCompletedPayload {
    let invocationId: String
    let content: String
    let isError: Bool
    let durationMs: Int
    /// Tool-specific structured metadata.
    let details: [String: AnyCodable]?
    /// Canonical server failure envelope when this completed result is an error.
    let failure: CanonicalFailurePayload?
    let identity: ToolIdentity

    init?(from payload: [String: AnyCodable]) {
        // `content`, `isError`, `duration` are all non-optional on the
        // server's `ToolInvocationCompletedPayload`. Empty string is a legitimate
        // `content` value (tools that return no text); missing the key
        // entirely is a schema violation.
        guard
            let invocationId = payload.string("invocationId"),
            let toolName = payload.string("toolName"),
            let content = payload.string("content"),
            let isError = payload.bool("isError"),
            let durationMs = payload.int("duration")
        else {
            TronLogger.shared.warning(
                "tool.invocation.completed event missing required field(s) invocationId/toolName/content/isError/duration; dropping",
                category: .events
            )
            return nil
        }

        self.invocationId = invocationId
        self.content = content
        self.isError = isError
        self.durationMs = durationMs
        self.identity = ToolIdentity(
            toolName: toolName,
            traceId: payload.string("traceId"),
            rootInvocationId: payload.string("rootInvocationId"),
            themeColor: payload.string("themeColor"),
            presentationHints: payload.dict("presentationHints")?.mapValues { AnyCodable($0) }
        )

        self.details = payload.anyCodableDict("details")
        self.failure = CanonicalFailurePayload.fromDetails(self.details)
    }

}

// MARK: - Error Payloads

/// Payload for turn.failed event
/// Server: TurnFailedEvent.payload
struct TurnFailedPayload {
    let turn: Int
    let error: String
    let code: String?
    let category: String?
    let retryable: Bool?
    let recoverable: Bool
    let origin: String?
    let details: [String: AnyCodable]?
    let failure: CanonicalFailurePayload?
    let partialContent: String?

    var isCancellation: Bool {
        CanonicalFailurePayload.isTurnCancellation(code: code)
    }

    init?(from payload: [String: AnyCodable]) {
        let details = payload.anyCodableDict("details")
        let failure = CanonicalFailurePayload.fromDetails(details)

        // `turn` and `recoverable` are both non-optional on the server's
        // `TurnFailedPayload`. The server emits `turn: 0` for failures that
        // happened before a turn was assigned — a decoded `0` is meaningful,
        // a missing field is not.
        guard let error = failure?.message
                ?? payload.string("error")
                ?? payload.string("message"),
              let turn = payload.int("turn"),
              let recoverable = failure?.recoverable ?? payload.bool("recoverable") else {
            TronLogger.shared.warning(
                "turn.failed event missing required field(s) error/turn/recoverable; dropping",
                category: .events
            )
            return nil
        }

        self.turn = turn
        self.error = error
        self.code = failure?.code ?? payload.string("code")
        self.category = failure?.category ?? payload.string("category")
        self.retryable = failure?.retryable ?? payload.bool("retryable")
        self.recoverable = recoverable
        self.origin = failure?.origin ?? payload.string("origin")
        self.details = details
        self.failure = failure
        self.partialContent = payload.string("partialContent")
    }
}
