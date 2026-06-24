import Foundation

/// Plugin for handling agent error events.
/// These events signal errors during agent execution.
/// Enriched events include provider, category, suggestion, and retryable fields
/// for rendering as interactive notification pills.
enum ErrorPlugin: DispatchableEventPlugin {
    static let eventType = "error"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let code: String?
            let message: String?
            let error: String?
            let provider: String?
            let category: String?
            let suggestion: String?
            let retryable: Bool?
            let recoverable: Bool?
            let origin: String?
            let details: [String: AnyCodable]?
            let retryAfterMs: Int?
            let statusCode: Int?
            let errorType: String?
            let model: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let code: String
        let message: String
        let provider: String?
        let category: String?
        let suggestion: String?
        let retryable: Bool?
        let recoverable: Bool?
        let origin: String?
        let details: [String: AnyCodable]?
        let retryAfterMs: Int?
        let statusCode: Int?
        let errorType: String?
        let model: String?
        let failure: CanonicalFailurePayload?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        guard let failure = CanonicalFailurePayload.fromDetails(data.details) else {
            return nil
        }

        return Result(
            code: failure.code,
            message: failure.message,
            provider: failure.provider,
            category: failure.category,
            suggestion: failure.suggestion,
            retryable: failure.retryable,
            recoverable: failure.recoverable,
            origin: failure.origin,
            details: data.details,
            retryAfterMs: failure.retryAfterMs,
            statusCode: failure.statusCode,
            errorType: failure.errorType,
            model: failure.model,
            failure: failure
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleProviderError(r)
    }
}
