import Foundation

// MARK: - session.reconstruct RPC Types

/// Request parameters for `session.reconstruct`.
struct SessionReconstructParams: Encodable {
    let sessionId: String
    let limit: Int?
    let beforeSequence: Int64?
}

/// Response from `session.reconstruct`.
///
/// Returns the complete session state in one response: persisted events,
/// in-flight state (if agent is running), and session metadata. The client
/// uses `lastSequence` as its high-water mark for WebSocket event filtering.
struct SessionReconstructResult: Decodable {
    /// Persisted events in sequence order.
    let events: [RawEvent]
    /// True if older events exist (for pagination via `beforeSequence`).
    let hasMoreEvents: Bool
    /// Sequence number of the earliest event in this response.
    let oldestSequence: Int64?
    /// In-flight turn state (non-null only when agent is running).
    let inFlight: InFlightState?
    /// Highest assigned sequence (includes non-persisted events).
    let lastSequence: Int64
    /// Whether the agent is currently running.
    let isRunning: Bool
    /// Session metadata.
    let metadata: ReconstructMetadata
    /// Pending queued messages (server-sourced, drives pill UI).
    let pendingQueue: [PendingQueueItem]?
}

/// In-flight state for an active turn.
struct InFlightState: Decodable {
    /// Tool calls in the current turn (generating, running, completed, error).
    let toolCalls: [CurrentTurnToolCall]
    /// Ordered content sequence (text, thinking, tool references).
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
