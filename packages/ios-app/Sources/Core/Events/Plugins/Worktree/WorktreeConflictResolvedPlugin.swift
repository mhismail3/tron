import Foundation

enum WorktreeConflictResolvedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.conflict_resolved"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let path: String?
            let resolution: String?
            let remaining: UInt32?
        }
    }

    struct Result: EventResult {
        let path: String
        let resolution: String
        let remaining: UInt32
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            path: data.path ?? "",
            resolution: data.resolution ?? "",
            remaining: data.remaining ?? 0
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeConflictResolved(r)
    }
}
