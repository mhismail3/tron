import Foundation

/// Plugin for handling agent error events.
/// These events signal errors during agent execution.
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
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let code: String
        let message: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            code: event.data?.code ?? "UNKNOWN",
            message: event.data?.message ?? event.data?.error ?? "Unknown error"
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleAgentError(r.message)
    }
}
