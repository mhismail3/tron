import Foundation

/// Fires after `rebase_on_main` advances the session branch — clean path
/// or post-conflict-resolution. Invariant: the session branch tip has
/// moved to include main's commits.
enum WorktreeRebasedOnMainPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.rebased_on_main"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let mainBranch: String?
            let strategy: String?
            let oldBaseCommit: String?
            let newBaseCommit: String?
            let mainCommitsIncorporated: UInt64?
            let hadAutoStash: Bool?
        }
    }

    struct Result: EventResult {
        let mainBranch: String
        let strategy: String
        let oldBaseCommit: String
        let newBaseCommit: String
        let mainCommitsIncorporated: UInt64
        let hadAutoStash: Bool
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            mainBranch: data.mainBranch ?? "main",
            strategy: data.strategy ?? "rebase",
            oldBaseCommit: data.oldBaseCommit ?? "",
            newBaseCommit: data.newBaseCommit ?? "",
            mainCommitsIncorporated: data.mainCommitsIncorporated ?? 0,
            hadAutoStash: data.hadAutoStash ?? false
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeRebasedOnMain(r)
    }
}
