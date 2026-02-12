import Foundation

/// Plugin for handling area created events.
enum AreaCreatedPlugin: DispatchableEventPlugin {
    static let eventType = "area.created"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let areaId: String
            let title: String
            let status: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let areaId: String
        let title: String
        let status: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            areaId: event.data.areaId,
            title: event.data.title,
            status: event.data.status
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleAreaCreated(r)
    }
}
