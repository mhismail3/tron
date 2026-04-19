import Foundation

enum WorktreeMergeContinuedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.merge_continued"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let mergeCommit: String
            let strategy: String
            /// `"finalize" | "rebase_on_main" | "stash_pop"` — required on
            /// the wire for schema validation. iOS currently treats all
            /// origins identically here (clear banners, refresh status);
            /// not forwarded to `Result`.
            let origin: String
        }
    }

    struct Result: EventResult {
        let mergeCommit: String
        let strategy: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            mergeCommit: data.mergeCommit,
            strategy: data.strategy
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeMergeContinued(r)
    }
}
