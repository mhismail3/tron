import Foundation

/// Plugin for handling rules.activated events.
/// These events signal that scoped rules were dynamically activated
/// when the agent accessed files in a matching directory.
enum RulesActivatedPlugin: DispatchableEventPlugin {
    static let eventType = "rules.activated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let rules: [RuleEntry]
            let totalActivated: Int

            struct RuleEntry: Decodable, Sendable {
                let relativePath: String
                let scopeDir: String
            }
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let rules: [ActivatedRuleEntry]
        let totalActivated: Int
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        let entries = event.data.rules.map {
            ActivatedRuleEntry(relativePath: $0.relativePath, scopeDir: $0.scopeDir)
        }
        guard !entries.isEmpty else { return nil }
        return Result(rules: entries, totalActivated: event.data.totalActivated)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleRulesActivated(r)
    }
}
