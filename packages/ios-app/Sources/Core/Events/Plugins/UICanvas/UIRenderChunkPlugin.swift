import Foundation

/// Plugin for handling UI render chunk events.
/// These events deliver progressive JSON chunks for UI canvas rendering.
enum UIRenderChunkPlugin: DispatchableEventPlugin {
    static let eventType = "agent.ui_render_chunk"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let canvasId: String
            let chunk: String
            let accumulated: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let canvasId: String
        let chunk: String
        let accumulated: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            canvasId: event.data.canvasId,
            chunk: event.data.chunk,
            accumulated: event.data.accumulated
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleUIRenderChunk(r)
    }
}
