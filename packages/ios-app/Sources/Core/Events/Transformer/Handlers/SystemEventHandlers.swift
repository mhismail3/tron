import Foundation

/// Handlers for transforming system notification events into ChatMessages.
///
/// Handles: notification.interrupted, context.cleared, compact.boundary,
///          skill.removed, rules.loaded, stream.thinking_complete
enum SystemEventHandlers {

    /// Transform notification.interrupted event into a ChatMessage.
    ///
    /// Interrupted events indicate when user stops agent mid-execution.
    static func transformInterrupted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        return ChatMessage(
            role: .system,
            content: .interrupted,
            timestamp: timestamp
        )
    }

    /// Transform context.cleared event into a ChatMessage.
    ///
    /// Context cleared events indicate when conversation context was reset.
    static func transformContextCleared(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ContextClearedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .contextCleared(
                tokensBefore: parsed.tokensBefore,
                tokensAfter: parsed.tokensAfter
            ),
            timestamp: timestamp
        )
    }

    /// Transform compact.boundary event into a ChatMessage.
    ///
    /// Compaction events indicate when context was compressed to fit window.
    static func transformCompactBoundary(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = CompactBoundaryPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .compaction(
                tokensBefore: parsed.originalTokens,
                tokensAfter: parsed.compactedTokens,
                reason: parsed.reason,
                summary: parsed.summary
            ),
            timestamp: timestamp
        )
    }

    /// Transform skill.removed event into a ChatMessage.
    ///
    /// Skill removed events indicate when a skill was deactivated.
    static func transformSkillRemoved(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        logger: TronLogger = TronLogger.shared
    ) -> ChatMessage? {
        guard let skillName = payload["skillName"]?.value as? String else {
            logger.warning("skill.removed event missing skillName in payload", category: .events)
            return nil
        }

        return ChatMessage(
            role: .system,
            content: .skillRemoved(skillName: skillName),
            timestamp: timestamp
        )
    }

    /// Transform rules.loaded event into a ChatMessage.
    ///
    /// Rules loaded events indicate when CLAUDE.md or other rules files were loaded.
    static func transformRulesLoaded(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        logger: TronLogger = TronLogger.shared
    ) -> ChatMessage? {
        guard let totalFiles = payload["totalFiles"]?.value as? Int else {
            logger.warning("rules.loaded event missing totalFiles in payload", category: .events)
            return nil
        }

        // Only show notification if there are rules files
        guard totalFiles > 0 else { return nil }

        return ChatMessage(
            role: .system,
            content: .rulesLoaded(count: totalFiles),
            timestamp: timestamp
        )
    }

    /// Transform stream.thinking_complete event into a ChatMessage.
    ///
    /// Thinking complete events contain the final extended thinking content.
    static func transformThinkingComplete(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = ThinkingCompletePayload(from: payload)

        // Use preview for initial display; full content loaded lazily on tap
        let displayText = parsed.preview.isEmpty ? parsed.content : parsed.preview

        return ChatMessage(
            role: .assistant,
            content: .thinking(visible: displayText, isExpanded: false, isStreaming: false),
            timestamp: timestamp
        )
    }
}
