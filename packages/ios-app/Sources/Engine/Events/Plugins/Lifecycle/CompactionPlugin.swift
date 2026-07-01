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
            let success: Bool
            let tokensBefore: Int
            let tokensAfter: Int
            let compressionRatio: Double?
            let reason: String?
            let summary: String?
            let estimatedContextTokens: Int?
            let preservedTurns: Int?
            let summarizedTurns: Int?
            let contextControlActionResourceId: String?
            let contextControlSnapshotResourceId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let success: Bool
        let tokensBefore: Int
        let tokensAfter: Int
        let compressionRatio: Double
        let reason: String
        let summary: String?
        let estimatedContextTokens: Int?
        let preservedTurns: Int?
        let summarizedTurns: Int?
        let contextControlActionResourceId: String?
        let contextControlSnapshotResourceId: String?

        var tokensSaved: Int { tokensBefore - tokensAfter }

        init(
            success: Bool,
            tokensBefore: Int,
            tokensAfter: Int,
            compressionRatio: Double,
            reason: String,
            summary: String?,
            estimatedContextTokens: Int?,
            preservedTurns: Int?,
            summarizedTurns: Int?,
            contextControlActionResourceId: String? = nil,
            contextControlSnapshotResourceId: String? = nil
        ) {
            self.success = success
            self.tokensBefore = tokensBefore
            self.tokensAfter = tokensAfter
            self.compressionRatio = compressionRatio
            self.reason = reason
            self.summary = summary
            self.estimatedContextTokens = estimatedContextTokens
            self.preservedTurns = preservedTurns
            self.summarizedTurns = summarizedTurns
            self.contextControlActionResourceId = contextControlActionResourceId
            self.contextControlSnapshotResourceId = contextControlSnapshotResourceId
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        let ratio = event.data.compressionRatio ??
            (event.data.tokensBefore > 0 ? Double(event.data.tokensAfter) / Double(event.data.tokensBefore) : 1.0)
        return Result(
            success: event.data.success,
            tokensBefore: event.data.tokensBefore,
            tokensAfter: event.data.tokensAfter,
            compressionRatio: ratio,
            reason: event.data.reason ?? "auto",
            summary: event.data.summary,
            estimatedContextTokens: event.data.estimatedContextTokens,
            preservedTurns: event.data.preservedTurns,
            summarizedTurns: event.data.summarizedTurns,
            contextControlActionResourceId: event.data.contextControlActionResourceId,
            contextControlSnapshotResourceId: event.data.contextControlSnapshotResourceId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCompaction(r)
    }
}
