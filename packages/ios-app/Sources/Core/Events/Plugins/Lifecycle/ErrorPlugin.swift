import Foundation

/// Plugin for handling agent error events.
/// These events signal errors during agent execution.
/// Enriched events include provider, category, suggestion, and retryable fields
/// for rendering as interactive notification pills.
enum ErrorPlugin: DispatchableEventPlugin {
    static let eventType = "agent.error"

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
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            code: event.data?.code ?? "UNKNOWN",
            message: event.data?.message ?? event.data?.error ?? "Unknown error",
            provider: event.data?.provider,
            category: event.data?.category,
            suggestion: event.data?.suggestion,
            retryable: event.data?.retryable
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleProviderError(r)
    }
}
