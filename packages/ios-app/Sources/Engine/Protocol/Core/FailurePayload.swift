import Foundation

/// Server-authored failure envelope shared by engine protocol errors, live
/// events, durable event replay, and capability result details.
struct CanonicalFailurePayload: Codable, Equatable, Hashable, Sendable {
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

    init?(from payload: [String: AnyCodable]?) {
        guard let payload,
              let code = payload.string("code"),
              let category = payload.string("category"),
              let message = payload.string("message"),
              let retryable = payload.bool("retryable"),
              let recoverable = payload.bool("recoverable"),
              let origin = payload.string("origin") else {
            return nil
        }

        self.init(
            code: code,
            category: category,
            message: message,
            retryable: retryable,
            recoverable: recoverable,
            origin: origin,
            provider: payload.string("provider"),
            model: payload.string("model"),
            statusCode: payload.int("statusCode"),
            errorType: payload.string("errorType"),
            retryAfterMs: payload.int("retryAfterMs"),
            suggestion: payload.string("suggestion"),
            details: payload.anyCodableDict("details"),
            traceId: payload.string("traceId"),
            invocationId: payload.string("invocationId"),
            parentInvocationId: payload.string("parentInvocationId"),
            sessionId: payload.string("sessionId"),
            sourceEventId: payload.string("sourceEventId")
        )
    }

    static func fromDetails(_ details: [String: AnyCodable]?) -> CanonicalFailurePayload? {
        CanonicalFailurePayload(from: details?.anyCodableDict("failure"))
    }

    var asDetails: [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "code": AnyCodable(code),
            "category": AnyCodable(category),
            "message": AnyCodable(message),
            "retryable": AnyCodable(retryable),
            "recoverable": AnyCodable(recoverable),
            "origin": AnyCodable(origin),
        ]
        if let provider { payload["provider"] = AnyCodable(provider) }
        if let model { payload["model"] = AnyCodable(model) }
        if let statusCode { payload["statusCode"] = AnyCodable(statusCode) }
        if let errorType { payload["errorType"] = AnyCodable(errorType) }
        if let retryAfterMs { payload["retryAfterMs"] = AnyCodable(retryAfterMs) }
        if let suggestion { payload["suggestion"] = AnyCodable(suggestion) }
        if let details { payload["details"] = AnyCodable(details.mapValues(\.value)) }
        if let traceId { payload["traceId"] = AnyCodable(traceId) }
        if let invocationId { payload["invocationId"] = AnyCodable(invocationId) }
        if let parentInvocationId { payload["parentInvocationId"] = AnyCodable(parentInvocationId) }
        if let sessionId { payload["sessionId"] = AnyCodable(sessionId) }
        if let sourceEventId { payload["sourceEventId"] = AnyCodable(sourceEventId) }
        return payload
    }
}
