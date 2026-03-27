import Foundation

/// Plugin for handling memory updated events.
/// Emitted when the LLM summarizer completes (or when there's nothing new to retain).
/// iOS uses this to stop the spinner and show a notification pill in chat.
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
            let eventId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        /// Non-nil when memory was actually saved; nil means "nothing new to retain".
        let title: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(title: event.data.title)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMemoryUpdated(r)
    }
}
