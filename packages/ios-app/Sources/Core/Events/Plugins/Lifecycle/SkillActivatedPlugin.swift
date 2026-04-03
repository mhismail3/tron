import Foundation

/// Plugin for handling skill activated events.
/// These events signal that a skill was activated in the session (server-owned state).
enum SkillActivatedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.skill_activated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let skillName: String
            let source: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let skillName: String
        let source: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(skillName: event.data.skillName, source: event.data.source ?? "global")
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSkillActivated(r)
    }
}
