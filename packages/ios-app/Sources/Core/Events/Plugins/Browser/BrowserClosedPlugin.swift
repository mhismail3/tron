import Foundation

/// Plugin for handling browser closed events.
/// These events signal that the browser session was closed.
enum BrowserClosedPlugin: EventPlugin {
    static let eventType = "browser.closed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    // MARK: - Result

    struct Result: EventResult {
        let closedSessionId: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(closedSessionId: event.sessionId)
    }
}
