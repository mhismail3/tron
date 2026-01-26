import Foundation

/// Plugin for handling plan mode entered events.
/// These events signal that the agent entered plan mode.
enum PlanModeEnteredPlugin: EventPlugin {
    static let eventType = "plan.mode_entered"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let skillName: String
            let blockedTools: [String]
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let skillName: String
        let blockedTools: [String]
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            skillName: event.data.skillName,
            blockedTools: event.data.blockedTools
        )
    }
}
