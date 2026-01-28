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
            let sessionId: String
            /// Base64-encoded frame data (named "data" in server response)
            let data: String
            let frameId: Int
            let timestamp: Double
            let metadata: Metadata?

            struct Metadata: Decodable, Sendable {
                let offsetTop: Double?
                let pageScaleFactor: Double?
                let deviceWidth: Double?
                let deviceHeight: Double?
                let scrollOffsetX: Double?
                let scrollOffsetY: Double?
            }
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
            frameData: event.data.data,
            format: nil,
            width: event.data.metadata?.deviceWidth.map { Int($0) },
            height: event.data.metadata?.deviceHeight.map { Int($0) }
        )
    }
}
