import Foundation

/// Plugin for handling context compaction events.
/// These events signal that the context was compacted to reduce token usage.
enum CompactionPlugin: DispatchableEventPlugin {
    static let eventType = "agent.compaction"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let tokensBefore: Int
            let tokensAfter: Int
            let compressionRatio: Double?
            let reason: String?
            let summary: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let tokensBefore: Int
        let tokensAfter: Int
        let compressionRatio: Double
        let reason: String
        let summary: String?

        var tokensSaved: Int { tokensBefore - tokensAfter }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        let ratio = event.data.compressionRatio ??
            (event.data.tokensBefore > 0 ? Double(event.data.tokensAfter) / Double(event.data.tokensBefore) : 1.0)
        return Result(
            tokensBefore: event.data.tokensBefore,
            tokensAfter: event.data.tokensAfter,
            compressionRatio: ratio,
            reason: event.data.reason ?? "auto",
            summary: event.data.summary
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCompaction(r)
    }
}
