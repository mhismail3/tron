import Foundation

/// Event projections for transforming system events into ChatMessages.
enum SystemEventProjection {

    static func transformModelChanged(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let previous = payload.string("previousModel"),
              let current = payload.string("newModel") else { return nil }
        return ChatMessage(
            role: .system,
            content: .modelChange(
                from: previous.shortModelName,
                to: current.shortModelName
            ),
            timestamp: timestamp
        )
    }

    static func transformReasoningChanged(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let current = payload.string("newLevel") else { return nil }
        let previous = payload.string("previousLevel") ?? "Default"
        return ChatMessage(
            role: .system,
            content: .reasoningLevelChange(
                from: previous.capitalized,
                to: current.capitalized
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
            content: .thinking(
                visible: displayText,
                isExpanded: false,
                isStreaming: false,
                kind: parsed.kind
            ),
            timestamp: timestamp
        )
    }

}
