import Foundation

/// Plugin for handling streaming capability output events.
/// These events deliver incremental stdout/stderr chunks while a capability is running.
enum CapabilityInvocationOutputPlugin: DispatchableEventPlugin {
    static let eventType = "capability.invocation.output"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let invocationId: String
            let output: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let invocationId: String
        let output: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            invocationId: event.data.invocationId,
            output: event.data.output
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityInvocationOutput(r)
    }
}
