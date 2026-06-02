import Foundation

/// Handlers for transforming system notification events into ChatMessages.
///
/// Handles: notification.interrupted, context.cleared, compact.boundary,
///          skills::deactivated, rules.loaded, stream.thinking_complete
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
                summary: parsed.summary,
                preservedTurns: parsed.preservedTurns,
                summarizedTurns: parsed.summarizedTurns
            ),
            timestamp: timestamp
        )
    }

    /// Transform skills::deactivated event into a ChatMessage.
    ///
    /// Skill deactivated events indicate when a skill was deactivated.
    static func transformSkillDeactivated(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        logger: TronLogger = TronLogger.shared
    ) -> ChatMessage? {
        guard let skillName = payload["skillName"]?.value as? String else {
            logger.warning("skills::deactivated event missing skillName in payload", category: .events)
            return nil
        }

        return ChatMessage(
            role: .system,
            content: .skillDeactivated(skillName: skillName),
            timestamp: timestamp
        )
    }

    /// Transform `skills.cleared` event into a ChatMessage.
    ///
    /// Emitted on the first prompt after a compaction boundary when the
    /// active skill set was non-empty. The `mode` discriminator controls
    /// rendering:
    ///
    /// - `.clearAll`: informational banner. The user can re-add skills
    ///   manually via `@skill-name`.
    /// - `.userInteraction`: interactive picker — each cleared skill becomes a
    ///   tappable chip that re-activates it via the `skills::activate` engine protocol.
    ///
    /// Returns `nil` (drops the message) when:
    /// - the payload is malformed (missing `clearedSkills`), OR
    /// - `clearedSkills` is empty — the server never emits this shape, but
    ///   rendering an empty picker / banner would be dead UI.
    ///
    /// Paired with M6 in the audit plan. The Rust emitter lives in the
    /// agent domain runtime and publishes through engine streams.
    static func transformSkillsCleared(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        logger: TronLogger = TronLogger.shared
    ) -> ChatMessage? {
        guard let parsed = SkillsClearedPayload(from: payload) else {
            logger.warning("skills.cleared event missing clearedSkills in payload", category: .events)
            return nil
        }
        guard !parsed.clearedSkills.isEmpty else {
            // Defensive: the server suppresses emission when the set would be
            // empty, but a future regression would otherwise render an empty
            // picker. Drop the message instead.
            logger.debug("skills.cleared event had empty clearedSkills; dropping", category: .events)
            return nil
        }

        return ChatMessage(
            role: .system,
            content: .skillsCleared(clearedSkills: parsed.clearedSkills, mode: parsed.mode),
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

    /// Transform rules.activated event into a ChatMessage.
    ///
    /// Rules activated events indicate when scoped rules were dynamically
    /// activated by file access in a matching directory.
    static func transformRulesActivated(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let totalActivated = payload["totalActivated"]?.value as? Int ?? 0
        var entries: [ActivatedRuleEntry] = []
        if let rulesValue = payload["rules"],
           let rulesArray = rulesValue.value as? [[String: Any]] {
            for dict in rulesArray {
                guard let relPath = dict["relativePath"] as? String,
                      let scopeDir = dict["scopeDir"] as? String else { continue }
                entries.append(ActivatedRuleEntry(relativePath: relPath, scopeDir: scopeDir))
            }
        }
        guard !entries.isEmpty else { return nil }
        return ChatMessage(
            role: .system,
            content: .rulesActivated(rules: entries, totalActivated: totalActivated),
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
        guard let parsed = ThinkingCompletePayload(from: payload) else {
            return nil
        }

        // Use preview for initial display; full content loaded lazily on tap
        let displayText = parsed.preview.isEmpty ? parsed.content : parsed.preview

        return ChatMessage(
            role: .assistant,
            content: .thinking(visible: displayText, isExpanded: false, isStreaming: false),
            timestamp: timestamp
        )
    }

    /// Transform memory.retained event into a ChatMessage.
    ///
    /// Memory retained events indicate when a session was summarized to long-term memory.
    static func transformMemoryRetained(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let title = payload["title"]?.value as? String
        let summary = payload["summary"]?.value as? String
        return ChatMessage(
            role: .system,
            content: .memoryRetained(title: title ?? "Session summary", summary: summary),
            timestamp: timestamp
        )
    }

    /// Transform memory.auto_retain_failed event into a ChatMessage.
    ///
    /// Reconstructed history shows the failure as a diagnostic breadcrumb
    /// in addition to the subsequent summary `memoryRetained`
    /// pill, so users can tell which session summaries came from a
    /// failing summarizer.
    static func transformMemoryAutoRetainFailed(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let intervalFired = (payload["intervalFired"]?.value as? Int) ?? 0
        let reason = (payload["reason"]?.value as? String) ?? "unknown"
        return ChatMessage(
            role: .system,
            content: .memoryAutoRetainFailed(intervalFired: intervalFired, reason: reason),
            timestamp: timestamp
        )
    }
}
