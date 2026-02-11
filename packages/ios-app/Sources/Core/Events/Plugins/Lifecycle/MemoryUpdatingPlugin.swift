import Foundation

/// Plugin for handling memory updating events.
/// Emitted when memory ledger write begins, before the LLM summarizer call.
/// iOS uses this to show a spinning "Retaining memory..." pill.
enum MemoryUpdatingPlugin: DispatchableEventPlugin {
    static let eventType = "agent.memory_updating"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {}
    }

    // MARK: - Result

    struct Result: EventResult {}

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result()
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMemoryUpdating(r)
    }
}
