import Foundation

/// Plugin for handling compaction started events.
/// Emitted when context compaction begins, before the LLM summarizer call.
/// iOS uses this to show a spinning "Compacting..." pill and block the send button.
enum CompactionStartedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.compaction_started"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let reason: String?
            let tokensBefore: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let reason: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(reason: event.data.reason ?? "auto")
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCompactionStarted(r)
    }
}
