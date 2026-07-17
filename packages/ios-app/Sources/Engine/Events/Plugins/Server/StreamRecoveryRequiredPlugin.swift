import Foundation

/// Global continuity marker emitted when either the server projection lane or
/// a local bounded subscriber buffer loses live event delivery. Mounted views
/// recover through the normal reconstruction owner instead of trusting the
/// remaining live suffix.
enum StreamRecoveryRequiredPlugin: DispatchableEventPlugin {
    static let eventType = "stream.recovery_required"

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?
        let data: DataPayload

        /// Recovery markers are global so every scoped subscriber can heal.
        var sessionId: String? { nil }

        struct DataPayload: Decodable, Sendable {
            let reason: String
            let droppedEventCount: UInt64
        }
    }

    struct Result: EventResult {
        let reason: String
        let droppedEventCount: UInt64
    }

    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            reason: event.data.reason,
            droppedEventCount: event.data.droppedEventCount
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleStreamRecoveryRequired(result)
    }
}
