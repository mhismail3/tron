import Foundation

/// Plugin for handling render_ui.started events.
/// Opens the WKWebView sheet to display the rendered UI.
enum RenderUIStartedPlugin: DispatchableEventPlugin {
    static let eventType = "render_ui.started"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let url: String
            let title: String?
            let toolCallId: String
        }
    }

    struct Result: EventResult {
        let canvasId: String
        let url: String
        let title: String?
        let toolCallId: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            url: event.data.url,
            title: event.data.title,
            toolCallId: event.data.toolCallId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleRenderUIStarted(r)
    }
}
