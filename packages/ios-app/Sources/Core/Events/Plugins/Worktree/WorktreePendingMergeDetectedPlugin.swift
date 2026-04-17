import Foundation

enum WorktreePendingMergeDetectedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.pending_merge_detected"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sourceBranch: String?
            let targetBranch: String?
            let strategy: String?
            let startedAtMs: UInt64?
            let autoAbortAtMs: UInt64?
        }
    }

    struct Result: EventResult {
        let sourceBranch: String
        let targetBranch: String
        let strategy: String
        let startedAtMs: UInt64
        let autoAbortAtMs: UInt64
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            sourceBranch: data.sourceBranch ?? "",
            targetBranch: data.targetBranch ?? "",
            strategy: data.strategy ?? "",
            startedAtMs: data.startedAtMs ?? 0,
            autoAbortAtMs: data.autoAbortAtMs ?? 0
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreePendingMergeDetected(r)
    }
}
