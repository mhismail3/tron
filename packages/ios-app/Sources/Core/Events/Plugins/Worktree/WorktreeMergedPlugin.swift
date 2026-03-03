import Foundation

/// Plugin for handling worktree.merged events.
/// Fired when a session's branch is merged into a target branch.
enum WorktreeMergedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.merged"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sourceBranch: String?
            let targetBranch: String?
            let mergeCommit: String?
            let strategy: String?
        }
    }

    struct Result: EventResult {
        let sourceBranch: String
        let targetBranch: String
        let mergeCommit: String?
        let strategy: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            sourceBranch: data.sourceBranch ?? "",
            targetBranch: data.targetBranch ?? "",
            mergeCommit: data.mergeCommit,
            strategy: data.strategy ?? ""
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeMerged(r)
    }
}
