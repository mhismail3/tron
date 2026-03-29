import Foundation
import UIKit

/// Plugin for handling `display.frame` events — live stream frames from the Display tool.
/// Decodes base64 JPEG data into a UIImage and dispatches to the ChatViewModel.
enum DisplayFramePlugin: DispatchableEventPlugin {
    static let eventType = "display.frame"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let streamId: String?
            let toolCallId: String?
            let data: String?       // base64 JPEG
            let frameId: Int?
            let width: Int?
            let height: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let streamId: String
        let toolCallId: String
        let image: UIImage
        let frameId: Int
        let width: Int
        let height: Int
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let payload = event.data,
              let streamId = payload.streamId,
              let toolCallId = payload.toolCallId,
              let b64 = payload.data,
              let imageData = Data(base64Encoded: b64),
              let image = UIImage(data: imageData) else {
            return nil
        }

        return Result(
            streamId: streamId,
            toolCallId: toolCallId,
            image: image,
            frameId: payload.frameId ?? 0,
            width: payload.width ?? 0,
            height: payload.height ?? 0
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleDisplayFrame(r)
    }
}
