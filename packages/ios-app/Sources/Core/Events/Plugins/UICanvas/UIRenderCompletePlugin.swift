import Foundation

/// Plugin for handling UI render complete events.
/// These events signal the completion of UI canvas rendering with final state.
enum UIRenderCompletePlugin: EventPlugin {
    static let eventType = "agent.ui_render_complete"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let ui: [String: AnyCodable]?
            let state: [String: AnyCodable]?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let canvasId: String
        let ui: [String: AnyCodable]?
        let state: [String: AnyCodable]?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            ui: event.data.ui,
            state: event.data.state
        )
    }
}
