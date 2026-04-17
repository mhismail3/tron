import Foundation

enum WorktreeConflictDetectedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.conflict_detected"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sourceBranch: String?
            let targetBranch: String?
            let paths: [String]?
        }
    }

    struct Result: EventResult {
        let sourceBranch: String
        let targetBranch: String
        let paths: [String]
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            sourceBranch: data.sourceBranch ?? "",
            targetBranch: data.targetBranch ?? "",
            paths: data.paths ?? []
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeConflictDetected(r)
    }
}
