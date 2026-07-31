import Foundation

// MARK: - Chat Message Model

struct AgentDeliveryMessageProvenance: Decodable, Equatable, Sendable {
    let deliveryId: String
    let sourceKind: String
    let sourceWorkerId: String?
    let sourceWorkerName: String?
    let sourceSessionId: String?
    let sourceInvocationId: String?
    let wakePolicy: String?
    let boundary: String?
    let triggeredWake: Bool?
    let redelivery: Bool
    let includedInThisTurn: Bool?
}

struct AgentDeliveryContinuationPayload: Decodable, Sendable {
    let deliveries: [AgentDeliveryMessageProvenance]
}

fileprivate struct AgentDeliveryContinuationPresentationKey: Hashable {
    let deliveryId: String
    let redelivery: Bool
}

enum AgentDeliveryContinuationPresentation {
    static func label(_ deliveries: [AgentDeliveryMessageProvenance]) -> String {
        guard !deliveries.isEmpty else { return "Agent update included" }
        let resumed = deliveries.contains(where: { $0.triggeredWake == true })
        if deliveries.count > 1 {
            let carriedOnly = deliveries.allSatisfy {
                $0.includedInThisTurn == false
            }
            return resumed
                ? "Resumed with \(deliveries.count) updates"
                : carriedOnly
                    ? "Response informed by \(deliveries.count) earlier updates"
                    : "\(deliveries.count) updates included"
        }
        let sources = Array(Set(deliveries.map {
            $0.sourceWorkerName
                ?? WorkerConsolePresentation.displayLabel($0.sourceWorkerId ?? $0.sourceKind)
        })).sorted()
        let source = sources.isEmpty ? "agent update" : sources.joined(separator: " + ")
        if resumed {
            return "Resumed from \(source)"
        }
        if deliveries[0].includedInThisTurn == false {
            return "Update used earlier · \(source)"
        }
        return "Update included · \(source)"
    }

    /// Persisted assistant events retain delivery metadata on every provider
    /// turn that belongs to one resumed run. Chat presents that durable
    /// evidence once per logical run while preserving a later explicit
    /// redelivery of the same delivery ID.
    static func deduplicatingTranscript(_ messages: [ChatMessage]) -> [ChatMessage] {
        var tracker = AgentDeliveryContinuationPresentationTracker()
        return messages.compactMap { original in
            if original.role == .user {
                tracker.reset()
                return original
            }
            guard !original.agentDeliveryProvenance.isEmpty else {
                return original
            }
            var message = original
            message.agentDeliveryProvenance = tracker.takeUnpresented(
                original.agentDeliveryProvenance
            )
            if message.agentDeliveryProvenance.isEmpty,
               message.isDeliveryProvenanceOnly {
                return nil
            }
            return message
        }
    }

    fileprivate static func presentationKey(
        _ provenance: AgentDeliveryMessageProvenance
    ) -> AgentDeliveryContinuationPresentationKey {
        AgentDeliveryContinuationPresentationKey(
            deliveryId: provenance.deliveryId,
            redelivery: provenance.redelivery
        )
    }
}

struct AgentDeliveryContinuationPresentationTracker {
    private var presented = Set<AgentDeliveryContinuationPresentationKey>()

    mutating func takeUnpresented(
        _ deliveries: [AgentDeliveryMessageProvenance]
    ) -> [AgentDeliveryMessageProvenance] {
        deliveries.filter {
            presented.insert(
                AgentDeliveryContinuationPresentation.presentationKey($0)
            ).inserted
        }
    }

    mutating func reset() {
        presented.removeAll(keepingCapacity: true)
    }
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

    /// A zero-content row whose only visual purpose is to place durable
    /// delivery provenance before thinking, tools, and response text.
    var isDeliveryProvenanceOnly: Bool

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
        isDeliveryProvenanceOnly: Bool = false,
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
        self.isDeliveryProvenanceOnly = isDeliveryProvenanceOnly
        self.isFinalAssistantResponse = isFinalAssistantResponse
        self.eventId = eventId
    }

    static func deliveryContinuation(
        _ provenance: [AgentDeliveryMessageProvenance],
        timestamp: Date = Date(),
        turnNumber: Int? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: .text(""),
            timestamp: timestamp,
            turnNumber: turnNumber,
            agentDeliveryProvenance: provenance,
            isDeliveryProvenanceOnly: true
        )
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
