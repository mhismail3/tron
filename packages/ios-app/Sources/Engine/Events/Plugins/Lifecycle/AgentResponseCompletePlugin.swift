import Foundation

/// Plugin for the server's response-complete lifecycle event.
///
/// When text exists, a completed response with zero tool invocations is
/// guaranteed to be the final textual response. Tool-bearing responses
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
            let hasToolInvocations: Bool
            let toolInvocationCount: Int
            let agentDeliveryContinuation: AgentDeliveryContinuation?

            struct AgentDeliveryContinuation: Decodable, Sendable {
                let deliveries: [AgentDeliveryMessageProvenance]
            }
        }
    }

    struct Result: EventResult {
        let turnNumber: Int
        let hasToolInvocations: Bool
        let toolInvocationCount: Int
        let agentDeliveryProvenance: [AgentDeliveryMessageProvenance]

        init(
            turnNumber: Int,
            hasToolInvocations: Bool,
            toolInvocationCount: Int,
            agentDeliveryProvenance: [AgentDeliveryMessageProvenance] = []
        ) {
            self.turnNumber = turnNumber
            self.hasToolInvocations = hasToolInvocations
            self.toolInvocationCount = toolInvocationCount
            self.agentDeliveryProvenance = agentDeliveryProvenance
        }
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data,
              data.turn > 0,
              data.toolInvocationCount >= 0,
              data.hasToolInvocations == (data.toolInvocationCount > 0)
        else {
            return nil
        }

        return Result(
            turnNumber: data.turn,
            hasToolInvocations: data.hasToolInvocations,
            toolInvocationCount: data.toolInvocationCount,
            agentDeliveryProvenance:
                data.agentDeliveryContinuation?.deliveries ?? []
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleResponseComplete(result)
    }
}
