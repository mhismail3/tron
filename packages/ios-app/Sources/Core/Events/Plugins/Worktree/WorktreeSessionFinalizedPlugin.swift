import Foundation

enum WorktreeSessionFinalizedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.session_finalized"

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
            let newBranch: String?
            let newBaseCommit: String?
            let oldBranchDeleted: Bool?
            let oldBranchDeleteError: String?
        }
    }

    struct Result: EventResult {
        let sourceBranch: String
        let targetBranch: String
        let mergeCommit: String?
        let strategy: String
        let newBranch: String
        let newBaseCommit: String
        let oldBranchDeleted: Bool
        let oldBranchDeleteError: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            sourceBranch: data.sourceBranch ?? "",
            targetBranch: data.targetBranch ?? "",
            mergeCommit: data.mergeCommit,
            strategy: data.strategy ?? "",
            newBranch: data.newBranch ?? "",
            newBaseCommit: data.newBaseCommit ?? "",
            oldBranchDeleted: data.oldBranchDeleted ?? false,
            oldBranchDeleteError: data.oldBranchDeleteError
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeSessionFinalized(r)
    }
}
