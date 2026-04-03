import Foundation

/// Plugin for handling spell cast events.
/// These events signal that an ephemeral spell was cast for the next prompt.
enum SpellCastPlugin: DispatchableEventPlugin {
    static let eventType = "agent.spell_cast"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let spellName: String
            let source: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let spellName: String
        let source: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(spellName: event.data.spellName, source: event.data.source ?? "global")
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSpellCast(r)
    }
}
