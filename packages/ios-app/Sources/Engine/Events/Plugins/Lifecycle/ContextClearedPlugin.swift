import Foundation

/// Plugin for handling context cleared events.
/// These events signal that the context was cleared (e.g., via /clear command).
enum ContextClearedPlugin: DispatchableEventPlugin {
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
            let contextControlActionResourceId: String?
            let contextControlSnapshotResourceId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let tokensBefore: Int
        let tokensAfter: Int
        let contextControlActionResourceId: String?
        let contextControlSnapshotResourceId: String?

        var tokensFreed: Int { tokensBefore - tokensAfter }

        init(
            tokensBefore: Int,
            tokensAfter: Int,
            contextControlActionResourceId: String? = nil,
            contextControlSnapshotResourceId: String? = nil
        ) {
            self.tokensBefore = tokensBefore
            self.tokensAfter = tokensAfter
            self.contextControlActionResourceId = contextControlActionResourceId
            self.contextControlSnapshotResourceId = contextControlSnapshotResourceId
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            tokensBefore: event.data.tokensBefore,
            tokensAfter: event.data.tokensAfter,
            contextControlActionResourceId: event.data.contextControlActionResourceId,
            contextControlSnapshotResourceId: event.data.contextControlSnapshotResourceId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleContextCleared(r)
    }
}
