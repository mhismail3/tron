import Foundation

enum RepoMainAdvancedPlugin: DispatchableEventPlugin {
    static let eventType = "repo.main_advanced"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let repoRoot: String
            let oldHead: String
            let newHead: String
            let sourceSessionId: String
            let cause: String
        }
    }

    struct Result: EventResult {
        let repoRoot: String
        let oldHead: String
        let newHead: String
        let sourceSessionId: String
        let cause: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        let data = event.data
        return Result(
            repoRoot: data.repoRoot,
            oldHead: data.oldHead,
            newHead: data.newHead,
            sourceSessionId: data.sourceSessionId,
            cause: data.cause
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleRepoMainAdvanced(r)
    }
}
