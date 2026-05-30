import Foundation

enum WorktreeMainSyncedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.main_synced"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let mainBranch: String
            let oldHead: String
            let newHead: String
            let advancedBy: UInt64
        }
    }

    struct Result: EventResult {
        let mainBranch: String
        let oldHead: String
        let newHead: String
        let advancedBy: UInt64
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        let data = event.data
        return Result(
            mainBranch: data.mainBranch,
            oldHead: data.oldHead,
            newHead: data.newHead,
            advancedBy: data.advancedBy
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeMainSynced(r)
    }
}
