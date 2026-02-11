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
    /// Combines root-level files (totalFiles) with dynamic subfolder files (dynamicRulesCount).
    static func transformRulesLoaded(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        logger: TronLogger = TronLogger.shared
    ) -> ChatMessage? {
        let totalFiles = payload["totalFiles"]?.value as? Int ?? 0
        let dynamicCount = payload["dynamicRulesCount"]?.value as? Int ?? 0
        let combinedCount = totalFiles + dynamicCount

        guard combinedCount > 0 else { return nil }

        return ChatMessage(
            role: .system,
            content: .rulesLoaded(count: combinedCount),
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

    /// Transform memory.ledger event into a ChatMessage.
    ///
    /// Memory ledger events indicate when a ledger entry was written after a response cycle.
    static func transformMemoryLedger(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let title = payload["title"]?.value as? String ?? "Memory updated"
        let entryType = payload["entryType"]?.value as? String ?? "conversation"

        return ChatMessage(
            role: .system,
            content: .memoryUpdated(title: title, entryType: entryType),
            timestamp: timestamp
        )
    }

    /// Transform memory.loaded event into a ChatMessage.
    ///
    /// Memory loaded events indicate when memories were auto-injected at session start.
    static func transformMemoryLoaded(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let count = payload["count"]?.value as? Int, count > 0 else { return nil }

        return ChatMessage(
            role: .system,
            content: .memoriesLoaded(count: count),
            timestamp: timestamp
        )
    }

    /// Transform notification.subagent_result event into a ChatMessage.
    ///
    /// These events are persisted when a non-blocking subagent completes while
    /// the parent agent is idle, allowing the user to send results to the agent.
    static func transformSubagentResultNotification(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        logger: TronLogger = TronLogger.shared
    ) -> ChatMessage? {
        guard let subagentSessionId = payload["subagentSessionId"]?.value as? String else {
            logger.warning("notification.subagent_result event missing subagentSessionId", category: .events)
            return nil
        }

        let task = payload["task"]?.value as? String ?? "Sub-agent task"
        let success = payload["success"]?.value as? Bool ?? true

        // Create a short preview of the task for display
        let taskPreview = task.count > 50 ? String(task.prefix(50)) + "..." : task

        return ChatMessage(
            role: .system,
            content: .systemEvent(.subagentResultAvailable(
                subagentSessionId: subagentSessionId,
                taskPreview: taskPreview,
                success: success
            )),
            timestamp: timestamp
        )
    }
}
