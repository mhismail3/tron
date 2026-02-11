import Foundation

/// Plugin for handling task deleted events.
enum TaskDeletedPlugin: DispatchableEventPlugin {
    static let eventType = "task.deleted"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let taskId: String
            let title: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let taskId: String
        let title: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            taskId: event.data.taskId,
            title: event.data.title
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleTaskDeleted(r)
    }
}
