import Foundation

/// Plugin for `process.status_update` events — process promoted or cancelled.
enum ProcessStatusUpdatePlugin: DispatchableEventPlugin {
    static let eventType = "process.status_update"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let processId: String?
            let status: String?
        }
    }

    struct Result: EventResult {
        let processId: String
        let status: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let payload = event.data,
              let processId = payload.processId,
              let status = payload.status else {
            return nil
        }

        return Result(processId: processId, status: status)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleProcessStatusUpdate(r)
    }
}
