import Foundation

/// Plugin for handling UI render start events.
/// These events signal the beginning of UI canvas rendering.
enum UIRenderStartPlugin: DispatchableEventPlugin {
    static let eventType = "agent.ui_render_start"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let title: String?
            let toolCallId: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let canvasId: String
        let title: String?
        let toolCallId: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            title: event.data.title,
            toolCallId: event.data.toolCallId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleUIRenderStart(r)
    }
}
