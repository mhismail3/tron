import Foundation

/// Plugin for handling render_ui.ready events.
/// Updates the chip status to completed.
enum RenderUIReadyPlugin: DispatchableEventPlugin {
    static let eventType = "render_ui.ready"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let url: String
        }
    }

    struct Result: EventResult {
        let canvasId: String
        let url: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            url: event.data.url
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleRenderUIReady(r)
    }
}
