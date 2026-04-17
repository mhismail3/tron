import Foundation

enum WorktreeMergeStartedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.merge_started"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sourceBranch: String?
            let targetBranch: String?
            let strategy: String?
            let conflictCount: UInt32?
        }
    }

    struct Result: EventResult {
        let sourceBranch: String
        let targetBranch: String
        let strategy: String
        let conflictCount: UInt32
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            sourceBranch: data.sourceBranch ?? "",
            targetBranch: data.targetBranch ?? "",
            strategy: data.strategy ?? "",
            conflictCount: data.conflictCount ?? 0
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeMergeStarted(r)
    }
}
