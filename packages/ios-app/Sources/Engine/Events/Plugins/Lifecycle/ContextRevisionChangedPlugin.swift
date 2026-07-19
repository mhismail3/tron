import Foundation

/// Invalidation-only signal for the source-owned Context Revision projection.
/// Lifecycle payload details remain server evidence; the chat reconstructs the
/// bounded workflow snapshot instead of treating the signal as UI truth.
enum ContextRevisionChangedPlugin: DispatchableEventPlugin {
    static let eventType = "context_revision.changed"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    struct Result: EventResult {}

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result()
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleContextRevisionChanged(result)
    }
}
