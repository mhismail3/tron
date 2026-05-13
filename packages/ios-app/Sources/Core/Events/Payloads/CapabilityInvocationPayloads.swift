import Foundation

// MARK: - Capability Invocation Payloads

/// Payload for capability.invocation.started event
struct CapabilityInvocationStartedPayload {
    let invocationId: String
    let modelPrimitiveName: String
    let arguments: String  // JSON string for display
    let turn: Int
    let identity: CapabilityIdentity
    /// Full payload dict preserved so transformers can access
    /// server-enriched fields such as `interactionStatus` and `parsedAnswers`
    /// from `session::reconstruct` enrichment.
    let rawPayload: [String: AnyCodable]

    init?(from payload: [String: AnyCodable]) {
        // invocationId can be "invocationId" or "id".
        // `turn` is always emitted by `CapabilityInvocationStartedPayload` on the server
        // (non-optional `i64`) — dropping the back-compat `?? 1` default
        // keeps reconstruction from silently pinning a stray event to turn 1.
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
            contractId: payload.string("contractId"),
            implementationId: payload.string("implementationId"),
            functionId: payload.string("functionId"),
            pluginId: payload.string("pluginId"),
            workerId: payload.string("workerId"),
            schemaDigest: payload.string("schemaDigest"),
            catalogRevision: payload.uint64("catalogRevision"),
            trustTier: payload.string("trustTier"),
            riskLevel: payload.string("riskLevel"),
            effectClass: payload.string("effectClass"),
            traceId: payload.string("traceId"),
            rootInvocationId: payload.string("rootInvocationId"),
            bindingDecisionId: payload.string("bindingDecisionId")
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
            contractId: payload.string("contractId"),
            implementationId: payload.string("implementationId"),
            functionId: payload.string("functionId"),
            pluginId: payload.string("pluginId"),
            workerId: payload.string("workerId"),
            schemaDigest: payload.string("schemaDigest"),
            catalogRevision: payload.uint64("catalogRevision"),
            trustTier: payload.string("trustTier"),
            riskLevel: payload.string("riskLevel"),
            effectClass: payload.string("effectClass"),
            traceId: payload.string("traceId"),
            rootInvocationId: payload.string("rootInvocationId"),
            bindingDecisionId: payload.string("bindingDecisionId")
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

/// Payload for error.capability event
/// Server: ErrorCapabilityEvent.payload
struct CapabilityErrorPayload {
    let modelPrimitiveName: String
    let invocationId: String
    let error: String
    let code: String?

    init?(from payload: [String: AnyCodable]) {
        guard let modelPrimitiveName = payload.string("modelPrimitiveName"),
              let invocationId = payload.string("invocationId"),
              let error = payload.string("error") else {
            return nil
        }

        self.modelPrimitiveName = modelPrimitiveName
        self.invocationId = invocationId
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
