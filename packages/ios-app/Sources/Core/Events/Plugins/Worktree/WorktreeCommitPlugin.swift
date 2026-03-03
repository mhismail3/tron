import Foundation

/// Plugin for handling worktree.commit events.
/// Fired when a commit is made in a session's worktree.
enum WorktreeCommitPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.commit"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let commitHash: String?
            let message: String?
            let filesChanged: [String]?
            let insertions: Int?
            let deletions: Int?
        }
    }

    struct Result: EventResult {
        let commitHash: String
        let message: String
        let filesChanged: [String]
        let insertions: Int
        let deletions: Int
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            commitHash: data.commitHash ?? "",
            message: data.message ?? "",
            filesChanged: data.filesChanged ?? [],
            insertions: data.insertions ?? 0,
            deletions: data.deletions ?? 0
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeCommit(r)
    }
}
