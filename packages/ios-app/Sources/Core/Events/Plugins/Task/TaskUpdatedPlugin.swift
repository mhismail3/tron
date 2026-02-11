import Foundation

/// Plugin for handling task updated events.
enum TaskUpdatedPlugin: DispatchableEventPlugin {
    static let eventType = "task.updated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let taskId: String
            let title: String
            let status: String
            let changedFields: [String]
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let taskId: String
        let title: String
        let status: String
        let changedFields: [String]
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            taskId: event.data.taskId,
            title: event.data.title,
            status: event.data.status,
            changedFields: event.data.changedFields
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleTaskUpdated(r)
    }
}
