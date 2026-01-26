import Foundation

/// Plugin for handling forwarded subagent events.
/// These events forward inner events from subagents to the parent session.
enum SubagentEventPlugin: EventPlugin {
    static let eventType = "agent.subagent_event"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let subagentSessionId: String
            let event: InnerEvent
        }

        struct InnerEvent: Decodable, Sendable {
            let type: String
            let data: AnyCodable
            let timestamp: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let innerEventType: String
        let innerEventData: AnyCodable
        let innerEventTimestamp: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            innerEventType: event.data.event.type,
            innerEventData: event.data.event.data,
            innerEventTimestamp: event.data.event.timestamp
        )
    }
}
