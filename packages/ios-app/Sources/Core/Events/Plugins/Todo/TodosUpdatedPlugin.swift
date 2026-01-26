import Foundation

/// Plugin for handling todos updated events.
/// These events signal that the todo list was modified.
enum TodosUpdatedPlugin: EventPlugin {
    static let eventType = "agent.todos_updated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let todos: [RpcTodoItem]
            let restoredCount: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let todos: [RpcTodoItem]
        let restoredCount: Int
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            todos: event.data.todos,
            restoredCount: event.data.restoredCount ?? 0
        )
    }
}
