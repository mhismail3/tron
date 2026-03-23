import Foundation

/// Plugin for handling render_ui.error events.
/// Shows error in the chip and sheet.
enum RenderUIErrorPlugin: DispatchableEventPlugin {
    static let eventType = "render_ui.error"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let error: String
        }
    }

    struct Result: EventResult {
        let canvasId: String
        let error: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            error: event.data.error
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleRenderUIError(r)
    }
}
