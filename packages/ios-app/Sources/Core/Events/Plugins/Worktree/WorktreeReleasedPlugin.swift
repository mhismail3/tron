import Foundation

/// Plugin for handling worktree.released events.
/// Fired when a session's worktree is cleaned up.
enum WorktreeReleasedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.released"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let finalCommit: String?
            let branchPreserved: Bool?
            let deleted: Bool?
        }
    }

    struct Result: EventResult {
        let finalCommit: String?
        let branchPreserved: Bool
        let deleted: Bool
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            finalCommit: data.finalCommit,
            branchPreserved: data.branchPreserved ?? false,
            deleted: data.deleted ?? false
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreeReleased(r)
    }
}
