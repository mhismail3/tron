import Foundation

/// Fires when `git stash pop` after a successful rebase produces
/// unmerged paths. The stash stays on the stash stack; the user
/// resolves by running `git stash pop` manually and fixing conflicts.
enum WorktreePostRebaseStashConflictPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.post_rebase_stash_conflict"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let stashRef: String
            let paths: [String]
        }
    }

    struct Result: EventResult {
        let stashRef: String
        let paths: [String]
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        let data = event.data
        return Result(
            stashRef: data.stashRef,
            paths: data.paths
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreePostRebaseStashConflict(r)
    }
}
