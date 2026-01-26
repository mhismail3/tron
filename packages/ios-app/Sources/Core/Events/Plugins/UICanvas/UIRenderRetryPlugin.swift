import Foundation

/// Plugin for handling UI render retry events.
/// These events signal that UI canvas rendering is being retried after a validation failure.
enum UIRenderRetryPlugin: EventPlugin {
    static let eventType = "agent.ui_render_retry"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let attempt: Int
            let errors: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let canvasId: String
        let attempt: Int
        let errors: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            attempt: event.data.attempt,
            errors: event.data.errors
        )
    }
}
