import Foundation

enum RepoLockAcquiredPlugin: DispatchableEventPlugin {
    static let eventType = "repo.lock_acquired"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let repoRoot: String?
            let sessionId: String?
            let op: String?
        }
    }

    struct Result: EventResult {
        let repoRoot: String
        let holderSessionId: String
        let op: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        return Result(
            repoRoot: data.repoRoot ?? "",
            holderSessionId: data.sessionId ?? "",
            op: data.op ?? ""
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleRepoLockAcquired(r)
    }
}
