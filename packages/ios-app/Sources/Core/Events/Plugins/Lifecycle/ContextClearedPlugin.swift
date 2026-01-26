import Foundation

/// Plugin for handling context cleared events.
/// These events signal that the context was cleared (e.g., via /clear command).
enum ContextClearedPlugin: EventPlugin {
    static let eventType = "agent.context_cleared"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let tokensBefore: Int
            let tokensAfter: Int
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let tokensBefore: Int
        let tokensAfter: Int

        var tokensFreed: Int { tokensBefore - tokensAfter }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            tokensBefore: event.data.tokensBefore,
            tokensAfter: event.data.tokensAfter
        )
    }
}
