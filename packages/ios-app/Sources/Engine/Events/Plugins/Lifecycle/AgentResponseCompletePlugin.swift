import Foundation

/// Plugin for the server's response-complete lifecycle event.
///
/// When text exists, a completed response with zero capability invocations is
/// guaranteed to be the final textual response. Capability-bearing responses
/// are deliberately ineligible for a footer whether execution continues or
/// explicitly stops.
/// `agent.turn_end` supplies token/latency metadata after this plugin marks the
/// eligible response.
enum AgentResponseCompletePlugin: DispatchableEventPlugin {
    static let eventType = "agent.response_complete"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let turn: Int
            let hasCapabilityInvocations: Bool
            let capabilityInvocationCount: Int
        }
    }

    struct Result: EventResult {
        let turnNumber: Int
        let hasCapabilityInvocations: Bool
        let capabilityInvocationCount: Int
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data,
              data.turn > 0,
              data.capabilityInvocationCount >= 0,
              data.hasCapabilityInvocations == (data.capabilityInvocationCount > 0)
        else {
            return nil
        }

        return Result(
            turnNumber: data.turn,
            hasCapabilityInvocations: data.hasCapabilityInvocations,
            capabilityInvocationCount: data.capabilityInvocationCount
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleResponseComplete(result)
    }
}
