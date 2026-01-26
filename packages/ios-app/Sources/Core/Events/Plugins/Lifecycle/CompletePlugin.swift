import Foundation

/// Plugin for handling agent completion events.
/// These events signal the end of the agent's response.
enum CompletePlugin: EventPlugin {
    static let eventType = "agent.complete"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
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

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            success: event.data?.success ?? true,
            totalTokens: event.data?.totalTokens,
            totalTurns: event.data?.totalTurns
        )
    }
}
