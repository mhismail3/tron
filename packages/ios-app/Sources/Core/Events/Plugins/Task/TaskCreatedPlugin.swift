import Foundation

/// Plugin for handling task created events.
enum TaskCreatedPlugin: DispatchableEventPlugin {
    static let eventType = "task.created"

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
            let projectId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let taskId: String
        let title: String
        let status: String
        let projectId: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            taskId: event.data.taskId,
            title: event.data.title,
            status: event.data.status,
            projectId: event.data.projectId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleTaskCreated(r)
    }
}
