import Foundation

/// Plugin for handling connection established events.
/// These events signal that the WebSocket connection was established.
enum ConnectedPlugin: EventPlugin {
    /// Handles both "connection.established" and "system.connected" types.
    static let eventType = "connection.established"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?
        let data: DataPayload?

        /// Connection events don't have a sessionId field - always nil.
        var sessionId: String? { nil }

        struct DataPayload: Decodable, Sendable {
            let clientId: String?
            let serverId: String?
            let version: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let serverId: String?
        let version: String?
        let clientId: String?
    }

    // MARK: - Protocol Implementation

    /// Override: Connection events always return nil for sessionId.
    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            serverId: event.data?.serverId,
            version: event.data?.version,
            clientId: event.data?.clientId
        )
    }
}
