import Foundation

/// Plugin for handling skill removed events.
/// These events signal that a skill was removed from the session.
enum SkillRemovedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.skill_removed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let skillName: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let skillName: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(skillName: event.data.skillName)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSkillRemoved(r)
    }
}
