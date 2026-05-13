import Foundation

/// Plugin for `process.spawned` events — a managed process was started.
enum ProcessSpawnedPlugin: DispatchableEventPlugin {
    static let eventType = "process.spawned"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let processId: String?
            let label: String?
            let kind: String?
            let background: Bool?
            let invocationId: String?
        }
    }

    struct Result: EventResult {
        let processId: String
        let label: String
        let kind: String
        let background: Bool
        let invocationId: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let payload = event.data,
              let processId = payload.processId,
              let label = payload.label else {
            return nil
        }

        return Result(
            processId: processId,
            label: label,
            kind: payload.kind ?? "shell",
            background: payload.background ?? true,
            invocationId: payload.invocationId ?? ""
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleProcessSpawned(r)
    }
}
