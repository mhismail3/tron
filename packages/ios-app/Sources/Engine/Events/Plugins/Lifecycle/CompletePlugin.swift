import Foundation

/// Plugin for handling agent completion events.
/// These events signal the end of the agent's response.
enum CompletePlugin: DispatchableEventPlugin {
    static let eventType = "agent.complete"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let success: Bool?
            let totalTokens: TokenUsage?
            let totalTurns: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let success: Bool
        let totalTokens: TokenUsage?
        let totalTurns: Int?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            success: event.data?.success ?? true,
            totalTokens: event.data?.totalTokens,
            totalTurns: event.data?.totalTurns
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        context.handleComplete()
    }
}
