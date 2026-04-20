import Foundation

/// Plugin for handling automatic memory retention trigger events.
/// Emitted by the server when the agent run completes and the
/// `memory.autoRetainInterval` threshold was crossed, immediately
/// before the generic `memory_updating` event. Lets iOS render a
/// distinct "Auto-retaining" pill instead of the manual-retain one.
enum MemoryAutoRetainTriggeredPlugin: DispatchableEventPlugin {
    static let eventType = "agent.memory_auto_retain_triggered"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let turnNumber: Int64
            let intervalFired: Int
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let turnNumber: Int64
        let intervalFired: Int
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(turnNumber: event.data.turnNumber, intervalFired: event.data.intervalFired)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMemoryAutoRetainTriggered(r)
    }
}
