import Foundation

/// Invalidation-only signal for the source-owned delegation projection.
/// The payload never becomes UI truth; mounted chats reconstruct the bounded
/// workflow snapshot after each transition.
enum DelegationChangedPlugin: DispatchableEventPlugin {
    static let eventType = "delegation.changed"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let state: String?
        }
    }

    struct Result: EventResult {
        let state: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(state: event.data?.state)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleDelegationChanged(result)
    }
}
