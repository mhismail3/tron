import Foundation

/// Plugin for handling project created events.
enum ProjectCreatedPlugin: DispatchableEventPlugin {
    static let eventType = "project.created"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let projectId: String
            let title: String
            let status: String
            let areaId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let projectId: String
        let title: String
        let status: String
        let areaId: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            projectId: event.data.projectId,
            title: event.data.title,
            status: event.data.status,
            areaId: event.data.areaId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleProjectCreated(r)
    }
}
