import Foundation

/// Plugin for handling browser frame events.
/// These events deliver browser screenshot frames.
enum BrowserFramePlugin: EventPlugin {
    static let eventType = "browser.frame"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let frame: String  // Base64-encoded image data
            let format: String?
            let width: Int?
            let height: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let frameData: String  // Base64-encoded image data
        let format: String?
        let width: Int?
        let height: Int?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            frameData: event.data.frame,
            format: event.data.format,
            width: event.data.width,
            height: event.data.height
        )
    }
}
