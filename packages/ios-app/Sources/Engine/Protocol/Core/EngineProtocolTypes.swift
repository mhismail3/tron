import Foundation

// MARK: - Engine Protocol Base Types

struct EngineFunctionId: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

struct EngineIdempotencyKey: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static func userAction(_ action: String) -> EngineIdempotencyKey {
        EngineIdempotencyKey(rawValue: "ios:user-action:\(action):\(UUID().uuidString)")
    }
}

struct EngineStreamCursor: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func < (lhs: EngineStreamCursor, rhs: EngineStreamCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct EngineInvocationContext: Codable, Equatable, Sendable {
    var sessionId: String?
    var workspaceId: String?
    var traceId: String?
    var parentInvocationId: String?

    init(
        sessionId: String? = nil,
        workspaceId: String? = nil,
        traceId: String? = nil,
        parentInvocationId: String? = nil
    ) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.traceId = traceId
        self.parentInvocationId = parentInvocationId
    }
}

struct EngineInvocationOptions: Sendable {
    var context: EngineInvocationContext?
    var timeout: TimeInterval?

    init(
        context: EngineInvocationContext? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.context = context
        self.timeout = timeout
    }
}

struct EngineSubscription: Decodable, Equatable, Sendable {
    let subscriptionId: String
    let topic: String
    let cursor: UInt64
    let limit: Int
}

struct EngineStreamPage: Decodable, Sendable {
    let events: [EngineStreamEventFrame]
    let hasMore: Bool
    let nextCursor: UInt64?
}

struct EngineStreamEventFrame: Decodable, Sendable {
    let topic: String
    let cursor: UInt64
    let event: ServerEventPayload
}

struct EngineEventDelivery: Sendable {
    let topic: String?
    let subscriptionId: String?
    let cursor: EngineStreamCursor?
    let event: ServerEventPayload
    let eventData: Data
}

struct ServerEventPayload: Codable, Equatable, Sendable {
    let type: String
    let sessionId: String?
    let workspaceId: String?
    let timestamp: String
    let data: AnyCodable?
    let runId: String?
    let sequence: Int64?
    let traceId: String?
    let parentInvocationId: String?
    let sourceEventId: String?
    let sourceSequence: Int64?
    let streamCursor: UInt64?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case workspaceId
        case timestamp
        case data
        case runId
        case sequence
        case traceId
        case parentInvocationId
        case sourceEventId
        case sourceSequence
        case streamCursor
    }
}

struct EngineProtocolResponseFrame: Decodable {
    let type: String
    let id: String?
    let ok: Bool
    let result: AnyCodable?
    let error: EngineProtocolError?
    let traceId: String?
}

struct EngineFunctionCallEnvelope<R: Decodable>: Decodable {
    let child: EngineChildInvocation<R>
}

struct EngineChildInvocation<R: Decodable>: Decodable {
    let invocationId: String?
    let functionId: String?
    let traceId: String?
    let value: R?
    let error: EngineChildError?
    let replayedFrom: String?
}

struct EngineChildError: Decodable, Sendable {
    let kind: String?
    let message: String?
    let details: [String: AnyCodable]?

    var failure: CanonicalFailurePayload? {
        CanonicalFailurePayload.fromDetails(details)
    }
}

/// Known engine error codes from the server.
///
/// Adding a case here forces exhaustive switches to handle new typed errors at
/// compile time. Unknown server codes decode to nil
/// through `EngineProtocolError.errorCode` and callers keep the raw message.
enum EngineErrorCode: String, CaseIterable, Sendable {
    case sessionNotFound = "SESSION_NOT_FOUND"
    case agentNotRunning = "AGENT_NOT_RUNNING"
    case invalidParams = "INVALID_PARAMS"
    case unknownMessageType = "UNKNOWN_MESSAGE_TYPE"
    case capabilityNotFound = "CAPABILITY_NOT_FOUND"
    case invalidFunctionId = "INVALID_FUNCTION_ID"
    case unauthorized = "UNAUTHORIZED"
    case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    case internalError = "INTERNAL_ERROR"

    // Typed event-store errors — mirror the server's event-store error mapping.
    case eventNotFound = "EVENT_NOT_FOUND"
    case workspaceNotFound = "WORKSPACE_NOT_FOUND"
    case blobNotFound = "BLOB_NOT_FOUND"
    case eventStoreBusy = "EVENT_STORE_BUSY"
    case eventStoreFailure = "EVENT_STORE_FAILURE"

    // Typed auth errors — mirror the server's auth error mapping.
    case authNotConfigured = "AUTH_NOT_CONFIGURED"
    case authTokenExpired = "AUTH_TOKEN_EXPIRED"
    case authOauthError = "AUTH_OAUTH_ERROR"
    case authStorageError = "AUTH_STORAGE_ERROR"
    case authTransportError = "AUTH_TRANSPORT_ERROR"
}

/// Structured engine protocol error details.
struct EngineProtocolError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let category: String
    let message: String
    let retryable: Bool
    let recoverable: Bool
    let origin: String
    let provider: String?
    let model: String?
    let statusCode: Int?
    let errorType: String?
    let retryAfterMs: Int?
    let suggestion: String?
    let details: [String: AnyCodable]?
    let traceId: String?
    let invocationId: String?
    let parentInvocationId: String?
    let sessionId: String?
    let sourceEventId: String?

    init(
        code: String,
        category: String,
        message: String,
        retryable: Bool,
        recoverable: Bool,
        origin: String,
        provider: String? = nil,
        model: String? = nil,
        statusCode: Int? = nil,
        errorType: String? = nil,
        retryAfterMs: Int? = nil,
        suggestion: String? = nil,
        details: [String: AnyCodable]? = nil,
        traceId: String? = nil,
        invocationId: String? = nil,
        parentInvocationId: String? = nil,
        sessionId: String? = nil,
        sourceEventId: String? = nil
    ) {
        self.code = code
        self.category = category
        self.message = message
        self.retryable = retryable
        self.recoverable = recoverable
        self.origin = origin
        self.provider = provider
        self.model = model
        self.statusCode = statusCode
        self.errorType = errorType
        self.retryAfterMs = retryAfterMs
        self.suggestion = suggestion
        self.details = details
        self.traceId = traceId
        self.invocationId = invocationId
        self.parentInvocationId = parentInvocationId
        self.sessionId = sessionId
        self.sourceEventId = sourceEventId
    }

    init(failure: CanonicalFailurePayload) {
        self.init(
            code: failure.code,
            category: failure.category,
            message: failure.message,
            retryable: failure.retryable,
            recoverable: failure.recoverable,
            origin: failure.origin,
            provider: failure.provider,
            model: failure.model,
            statusCode: failure.statusCode,
            errorType: failure.errorType,
            retryAfterMs: failure.retryAfterMs,
            suggestion: failure.suggestion,
            details: failure.details,
            traceId: failure.traceId,
            invocationId: failure.invocationId,
            parentInvocationId: failure.parentInvocationId,
            sessionId: failure.sessionId,
            sourceEventId: failure.sourceEventId
        )
    }

    var failure: CanonicalFailurePayload {
        CanonicalFailurePayload(
            code: code,
            category: category,
            message: message,
            retryable: retryable,
            recoverable: recoverable,
            origin: origin,
            provider: provider,
            model: model,
            statusCode: statusCode,
            errorType: errorType,
            retryAfterMs: retryAfterMs,
            suggestion: suggestion,
            details: details,
            traceId: traceId,
            invocationId: invocationId,
            parentInvocationId: parentInvocationId,
            sessionId: sessionId,
            sourceEventId: sourceEventId
        )
    }

    var errorDescription: String? { message }

    /// Typed error code (nil for unknown codes)
    var errorCode: EngineErrorCode? { EngineErrorCode(rawValue: code) }

    /// Redacted one-line diagnostic for logs. This keeps client logs useful for
    /// server-contract failures without dumping request payloads or credentials.
    var diagnosticSummary: String {
        guard let details, !details.isEmpty else {
            return "\(code): \(message)"
        }

        let renderedDetails = Self.renderDetails(details, depth: 0)
        guard !renderedDetails.isEmpty else {
            return "\(code): \(message)"
        }

        let summary = "\(code): \(message) details={\(renderedDetails)}"
        if summary.count > 800 {
            return "\(summary.prefix(800))..."
        }
        return summary
    }

    private static func renderDetails(_ details: [String: AnyCodable], depth: Int) -> String {
        guard depth < 2 else { return "..." }

        return details.keys.sorted().prefix(12).compactMap { key in
            guard let value = details[key] else { return nil }
            return "\(key)=\(renderedValue(for: key, value: value, depth: depth))"
        }.joined(separator: " ")
    }

    private static func renderedValue(for key: String, value: AnyCodable, depth: Int) -> String {
        if shouldRedact(key) {
            return "redacted"
        }
        if let string = value.stringValue {
            return sanitized(string)
        }
        if let int = value.intValue {
            return "\(int)"
        }
        if let double = value.doubleValue {
            return "\(double)"
        }
        if let bool = value.boolValue {
            return "\(bool)"
        }
        if let dictionary = value.dictionaryValue {
            let nested = dictionary.mapValues { AnyCodable($0) }
            let rendered = renderDetails(nested, depth: depth + 1)
            return "{\(rendered)}"
        }
        if let array = value.arrayValue {
            let simple = array.compactMap { item -> String? in
                switch item {
                case let string as String: sanitized(string)
                case let int as Int: "\(int)"
                case let double as Double: "\(double)"
                case let bool as Bool: "\(bool)"
                default: nil
                }
            }
            if simple.count == array.count, !simple.isEmpty {
                return "[\(simple.prefix(6).joined(separator: ","))]"
            }
            return "[\(array.count) items]"
        }
        return "null"
    }

    private static func shouldRedact(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("payload")
            || normalized.contains("argument")
            || normalized.contains("input")
            || normalized.contains("request")
            || normalized.contains("response")
            || normalized.contains("authorization")
            || normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("api_key")
            || normalized == "key"
            || normalized == "value"
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

/// Empty params for methods that don't require parameters
struct EmptyParams: Codable {}
