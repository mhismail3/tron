import Foundation

enum WorktreePushedPlugin: DispatchableEventPlugin {
    static let eventType = "worktree.pushed"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let branch: String
            let remote: String
            let setUpstream: Bool
            let dryRun: Bool
            let forceWithLease: Bool
        }
    }

    struct Result: EventResult {
        let branch: String
        let remote: String
        let setUpstream: Bool
        let dryRun: Bool
        let forceWithLease: Bool
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        let data = event.data
        return Result(
            branch: data.branch,
            remote: data.remote,
            setUpstream: data.setUpstream,
            dryRun: data.dryRun,
            forceWithLease: data.forceWithLease
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleWorktreePushed(r)
    }
}
