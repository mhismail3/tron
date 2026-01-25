import Foundation

/// Handlers for transforming configuration change events into ChatMessages.
///
/// Handles: config.model_switch, config.reasoning_level
enum ConfigHandlers {

    /// Transform config.model_switch event into a ChatMessage.
    ///
    /// Model switch events indicate when the active model changes during a session.
    /// Displays the transition from previous model to new model.
    static func transformModelSwitch(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ModelSwitchPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .modelChange(
                from: formatModelDisplayName(parsed.previousModel),
                to: formatModelDisplayName(parsed.newModel)
            ),
            timestamp: timestamp
        )
    }

    /// Transform config.reasoning_level event into a ChatMessage.
    ///
    /// Reasoning level changes indicate when extended thinking mode is enabled/disabled.
    static func transformReasoningLevelChange(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = ReasoningLevelPayload(from: payload)

        // Need both previous and new levels to show a meaningful notification
        guard let previousLevel = parsed.previousLevel,
              let newLevel = parsed.newLevel else { return nil }

        return ChatMessage(
            role: .system,
            content: .reasoningLevelChange(
                from: previousLevel.capitalized,
                to: newLevel.capitalized
            ),
            timestamp: timestamp
        )
    }
}
