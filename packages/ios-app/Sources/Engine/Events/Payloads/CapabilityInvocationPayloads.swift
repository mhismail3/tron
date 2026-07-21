import Foundation

// MARK: - Capability Invocation Payloads

/// Payload for capability.invocation.started event
struct CapabilityInvocationStartedPayload {
    let invocationId: String
    let modelPrimitiveName: String
    let arguments: String  // JSON string for display
    let turn: Int
    let identity: CapabilityIdentity
    /// Full payload dict preserved so transformers can access primitive trace
    /// and presentation metadata.
    let rawPayload: [String: AnyCodable]

    init?(from payload: [String: AnyCodable]) {
        // invocationId can be "invocationId" or "id".
        // `turn` is required; missing turn data makes the event invalid.
        guard let id = payload.string("invocationId") ?? payload.string("id"),
              let modelPrimitiveName = payload.string("modelPrimitiveName"),
              let turn = payload.int("turn") else {
            TronLogger.shared.warning(
                "capability.invocation.started event missing required field(s) invocationId/modelPrimitiveName/turn; dropping",
                category: .events
            )
            return nil
        }

        self.invocationId = id
        self.modelPrimitiveName = modelPrimitiveName
        self.turn = turn
        self.rawPayload = payload
        self.identity = CapabilityIdentity(
            modelPrimitiveName: modelPrimitiveName,
            operationName: payload.string("operationName") ?? payload.string("operation"),
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

    var name: String { modelPrimitiveName }
}

/// Payload for capability.invocation.completed event
struct CapabilityInvocationCompletedPayload {
    let invocationId: String
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
    /// Capability-specific structured metadata.
    let details: [String: AnyCodable]?
    /// Canonical server failure envelope when this completed result is an error.
    let failure: CanonicalFailurePayload?
    let identity: CapabilityIdentity

    init?(from payload: [String: AnyCodable]) {
        // `content`, `isError`, `duration` are all non-optional on the
        // server's `CapabilityInvocationCompletedPayload`. Empty string is a legitimate
        // `content` value (capabilities that return no text); missing the key
        // entirely is a schema violation.
        guard
            let invocationId = payload.string("invocationId"),
            let modelPrimitiveName = payload.string("modelPrimitiveName"),
            let content = payload.string("content"),
            let isError = payload.bool("isError"),
            let durationMs = payload.int("duration")
        else {
            TronLogger.shared.warning(
                "capability.invocation.completed event missing required field(s) invocationId/modelPrimitiveName/content/isError/duration; dropping",
                category: .events
            )
            return nil
        }

        self.invocationId = invocationId
        self.content = content
        self.isError = isError
        self.durationMs = durationMs
        self.affectedFiles = payload.stringArray("affectedFiles")
        self.truncated = payload.bool("truncated")
        self.blobId = payload.string("blobId")
        self.identity = CapabilityIdentity(
            modelPrimitiveName: modelPrimitiveName,
            operationName: payload.string("operationName") ?? payload.string("operation"),
            traceId: payload.string("traceId"),
            rootInvocationId: payload.string("rootInvocationId"),
            themeColor: payload.string("themeColor"),
            presentationHints: payload.dict("presentationHints")?.mapValues { AnyCodable($0) }
        )

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

        // Capability-specific details (new field persisted by Rust agent)
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
        CanonicalFailurePayload.isTurnCancellation(code: code, category: category)
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
