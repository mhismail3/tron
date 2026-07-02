import Foundation

/// Plugin for the server's authoritative thinking-end snapshot.
enum ThinkingEndPlugin: DispatchableEventPlugin {
    static let eventType = "agent.thinking_end"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let thinking: String
            let kind: String?
        }
    }

    struct Result: EventResult {
        let thinking: String
        let kind: ThinkingDisplayKind
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(thinking: event.data.thinking, kind: ThinkingDisplayKind(serverValue: event.data.kind))
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleThinkingEnd(r.thinking, kind: r.kind)
    }
}
