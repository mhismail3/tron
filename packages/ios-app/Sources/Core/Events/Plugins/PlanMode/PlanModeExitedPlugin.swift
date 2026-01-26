import Foundation

/// Plugin for handling plan mode exited events.
/// These events signal that the agent exited plan mode.
enum PlanModeExitedPlugin: EventPlugin {
    static let eventType = "plan.mode_exited"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let reason: String  // "approved", "cancelled", "timeout"
            let planPath: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let reason: String
        let planPath: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            reason: event.data.reason,
            planPath: event.data.planPath
        )
    }
}
