import Foundation

// MARK: - Chat Message Model

struct AgentDeliveryMessageProvenance: Decodable, Equatable, Sendable {
    let deliveryId: String
    let sourceKind: String
    let sourceSessionId: String?
    let sourceInvocationId: String?
    let redelivery: Bool
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    /// Version counter for streaming updates (triggers SwiftUI onChange reliably)
    var streamingVersion: Int = 0
    /// Token record with source, computed, and metadata
    var tokenRecord: TokenRecord?
    /// Files attached to this message (unified model - images, PDFs, documents)
    var attachments: [Attachment]?

    // MARK: - Server Metadata

    /// Model that generated this response (e.g., "claude-sonnet-4-20250514")
    var model: String?

    /// Response latency in milliseconds
    var latencyMs: Int?

    /// Turn number in the agent loop
    var turnNumber: Int?

    /// Whether extended thinking was used
    var hasThinking: Bool?

    /// Minimal durable provenance for a delivery-only assistant continuation.
    /// Content remains inspectable through Session Context; chat carries only
    /// enough identity to explain why the assistant resumed without a user row.
    var agentDeliveryProvenance: [AgentDeliveryMessageProvenance]

    /// Server-backed finality for the textual response that ends a prompt
    /// cycle. Live events set this from `agent.response_complete`; replay sets
    /// it from the persisted assistant payload's tool blocks.
    var isFinalAssistantResponse: Bool

    /// Event ID from the server's event store (for deletion, forking, etc.)
    var eventId: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: MessageContent,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        streamingVersion: Int = 0,
        tokenRecord: TokenRecord? = nil,
        attachments: [Attachment]? = nil,
        model: String? = nil,
        latencyMs: Int? = nil,
        turnNumber: Int? = nil,
        hasThinking: Bool? = nil,
        agentDeliveryProvenance: [AgentDeliveryMessageProvenance] = [],
        isFinalAssistantResponse: Bool = false,
        eventId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.streamingVersion = streamingVersion
        self.tokenRecord = tokenRecord
        self.attachments = attachments
        self.model = model
        self.latencyMs = latencyMs
        self.turnNumber = turnNumber
        self.hasThinking = hasThinking
        self.agentDeliveryProvenance = agentDeliveryProvenance
        self.isFinalAssistantResponse = isFinalAssistantResponse
        self.eventId = eventId
    }

    var formattedTimestamp: String {
        DateParser.formatTime(timestamp)
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

    /// Metadata eligible for display beneath the response marked final by the
    /// live/replay projection boundary. Visual order and raw stop reason are
    /// deliberately not consulted here.
    var finalAssistantResponseMetadata: FinalAssistantResponseMetadata? {
        guard role == .assistant,
              case .text = content,
              isFinalAssistantResponse
        else {
            return nil
        }

        let metadata = FinalAssistantResponseMetadata(
            tokenRecord: tokenRecord,
            model: shortModelName,
            latency: formattedLatency
        )
        return metadata.isEmpty ? nil : metadata
    }

    /// Applies per-response metadata only when the live/replay projection
    /// boundary marks textual assistant content as terminal for the prompt
    /// cycle.
    mutating func applyFinalAssistantResponseMetadata(
        tokenRecord: TokenRecord?,
        model: String?,
        latencyMs: Int?
    ) {
        guard role == .assistant,
              content.isAssistantResponseText,
              isFinalAssistantResponse
        else {
            return
        }

        self.tokenRecord = tokenRecord
        self.model = model
        self.latencyMs = latencyMs
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

/// Display-ready metadata for the final assistant response in a prompt cycle.
struct FinalAssistantResponseMetadata {
    let tokenRecord: TokenRecord?
    let model: String?
    let latency: String?

    var isEmpty: Bool {
        tokenRecord == nil && model == nil && latency == nil
    }
}
