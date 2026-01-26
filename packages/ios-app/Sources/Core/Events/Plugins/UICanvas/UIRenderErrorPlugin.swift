import Foundation

/// Plugin for handling UI render error events.
/// These events signal errors during UI canvas rendering.
enum UIRenderErrorPlugin: EventPlugin {
    static let eventType = "agent.ui_render_error"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let error: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let canvasId: String
        let error: String
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            error: event.data.error
        )
    }
}
