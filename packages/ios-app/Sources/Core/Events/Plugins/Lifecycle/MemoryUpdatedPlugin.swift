import Foundation

/// Plugin for handling memory ledger update events.
/// These events signal that a memory ledger entry was written after a response cycle.
enum MemoryUpdatedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.memory_updated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let title: String?
            let entryType: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let title: String
        let entryType: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            title: event.data.title ?? "Memory updated",
            entryType: event.data.entryType ?? "conversation"
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMemoryUpdated(r)
    }
}
