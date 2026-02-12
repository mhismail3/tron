import Foundation

/// Plugin for handling area deleted events.
enum AreaDeletedPlugin: DispatchableEventPlugin {
    static let eventType = "area.deleted"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let areaId: String
            let title: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let areaId: String
        let title: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            areaId: event.data.areaId,
            title: event.data.title
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleAreaDeleted(r)
    }
}
