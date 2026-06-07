import Foundation

// MARK: - session::reconstruct engine protocol Types

/// Request parameters for `session::reconstruct`.
struct SessionReconstructParams: Encodable {
    let sessionId: String
    let limit: Int?
    let beforeEventId: String?
}

/// Response from `session::reconstruct`.
///
/// Returns the complete session state in one response: persisted events,
/// in-flight state (if agent is running), and session metadata. The client
/// uses `lastSequence` as its high-water mark for WebSocket event filtering.
struct SessionReconstructResult: Decodable {
    /// Persisted events in sequence order.
    let events: [RawEvent]
    /// True if older events exist (for pagination via `beforeEventId`).
    let hasMoreEvents: Bool
    /// Event ID of the earliest event in this response.
    let oldestEventId: String?
    /// In-flight turn state (non-null only when agent is running).
    let inFlight: InFlightState?
    /// Highest assigned sequence (includes non-persisted events).
    let lastSequence: Int64
    /// Whether the agent is currently running.
    let isRunning: Bool
    /// Server-authoritative agent phase ("processing", "postProcessing", "idle").
    let agentPhase: String?
    /// Session metadata.
    let metadata: ReconstructMetadata
    /// Pending queued messages (server-sourced, drives pill UI).
    let pendingQueue: [PendingQueueItem]?
}

/// In-flight state for an active turn.
struct InFlightState: Decodable {
    /// Capability invocations in the current turn (generating, running, completed, error).
    let capabilityInvocations: [CurrentTurnCapabilityInvocation]
    /// Ordered content sequence (text, thinking, capability references).
    let contentSequence: [ContentSequenceItem]
    /// Currently streaming content (text or thinking delta).
    let streaming: InFlightStreaming?
}

/// Currently streaming content from the LLM.
struct InFlightStreaming: Decodable {
    /// Content type: "text" or "thinking".
    let type: String
    /// Accumulated content so far.
    let content: String
}

/// Session metadata from reconstruction.
struct ReconstructMetadata: Decodable {
    let model: String?
    let turnCount: Int?
    let workingDirectory: String?
    let title: String?
    let tokenUsage: ReconstructTokenUsage?
    let totalCost: Double?
}

/// Token usage from reconstruction metadata.
struct ReconstructTokenUsage: Decodable {
    let input: Int64?
    let output: Int64?
    let cacheRead: Int64?
    let cacheCreation: Int64?
}
