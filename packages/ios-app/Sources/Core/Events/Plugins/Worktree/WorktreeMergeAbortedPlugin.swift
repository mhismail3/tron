import Foundation

enum WorktreeMergeAbortedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.merge_aborted"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let strategy: String?
            let reason: String?
        }
    }

    struct Result: EventResult {
        let strategy: String
        let reason: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            strategy: data.strategy ?? "",
            reason: data.reason ?? ""
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeMergeAborted(r)
    }
}
