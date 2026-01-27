import Foundation

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    /// Version counter for streaming updates (triggers SwiftUI onChange reliably)
    var streamingVersion: Int = 0
    var tokenUsage: TokenUsage?
    /// Incremental token usage (delta from previous turn) for display purposes
    var incrementalTokens: TokenUsage?
    /// Files attached to this message (unified model - images, PDFs, documents)
    var attachments: [Attachment]?
    /// Skills referenced in this message (rendered as chips above the message)
    var skills: [Skill]?
    /// Spells referenced in this message (ephemeral skills, rendered as pink chips)
    var spells: [Skill]?

    // MARK: - Enriched Metadata (Phase 1)
    // These fields come from server-side event store enhancements

    /// Model that generated this response (e.g., "claude-sonnet-4-20250514")
    var model: String?

    /// Response latency in milliseconds
    var latencyMs: Int?

    /// Turn number in the agent loop
    var turnNumber: Int?

    /// Whether extended thinking was used
    var hasThinking: Bool?

    /// Why the turn ended (end_turn, tool_use, max_tokens)
    var stopReason: String?

    /// Event ID from the server's event store (for deletion, forking, etc.)
    var eventId: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: MessageContent,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        streamingVersion: Int = 0,
        tokenUsage: TokenUsage? = nil,
        incrementalTokens: TokenUsage? = nil,
        attachments: [Attachment]? = nil,
        skills: [Skill]? = nil,
        spells: [Skill]? = nil,
        model: String? = nil,
        latencyMs: Int? = nil,
        turnNumber: Int? = nil,
        hasThinking: Bool? = nil,
        stopReason: String? = nil,
        eventId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.streamingVersion = streamingVersion
        self.tokenUsage = tokenUsage
        self.incrementalTokens = incrementalTokens
        self.attachments = attachments
        self.skills = skills
        self.spells = spells
        self.model = model
        self.latencyMs = latencyMs
        self.turnNumber = turnNumber
        self.hasThinking = hasThinking
        self.stopReason = stopReason
        self.eventId = eventId
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    // MARK: - Formatted Metadata Helpers

    /// Format latency as human-readable string (e.g., "2.3s" or "450ms")
    var formattedLatency: String? {
        guard let ms = latencyMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Short model name (e.g., "claude-sonnet-4-20250514" -> "Sonnet 4")
    var shortModelName: String? {
        guard let model = model else { return nil }
        return model.shortModelName
    }

    /// Whether this message can be deleted.
    /// Only user and assistant messages with event IDs can be deleted.
    var canBeDeleted: Bool {
        // Must have an eventId (from server)
        guard eventId != nil else { return false }

        // Must be a user or assistant message (not system, toolResult, etc.)
        guard role == .user || role == .assistant else { return false }

        // Don't allow deleting streaming messages
        guard !isStreaming else { return false }

        return true
    }
}
