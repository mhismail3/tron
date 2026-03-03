import Foundation

/// Plugin for handling worktree.acquired events.
/// Fired when a session gets its own git worktree for isolation.
enum WorktreeAcquiredPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.acquired"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let path: String?
            let branch: String?
            let baseCommit: String?
            let baseBranch: String?
        }
    }

    struct Result: EventResult {
        let path: String
        let branch: String
        let baseCommit: String
        let baseBranch: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            path: data.path ?? "",
            branch: data.branch ?? "",
            baseCommit: data.baseCommit ?? "",
            baseBranch: data.baseBranch
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeAcquired(r)
    }
}
