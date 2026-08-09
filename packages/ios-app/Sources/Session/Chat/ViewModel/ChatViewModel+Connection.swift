import Foundation
import SwiftUI

// MARK: - ConnectionContext Conformance

extension ChatViewModel: ConnectionContext {

    var isConnected: Bool {
        services.connection.connectionState.isConnected
    }

    func connect() async {
        await services.connection.connect()
    }

    func resumeSession(sessionId: String) async throws {
        try await services.sessions.resume(
            sessionId: sessionId,
            idempotencyKey: .userAction("session.resume")
        )
    }

    func reconstructSession(sessionId: String, limit: Int?, beforeEventId: String?) async throws -> SessionReconstructResult {
        try await services.sessions.reconstruct(sessionId: sessionId, limit: limit, beforeEventId: beforeEventId)
    }

    var reconstructionEventLimit: Int {
        guard hasAuthoritativeHistory else {
            return Self.initialReconstructionEventLimit
        }

        let loadedDepth = max(loadedReconstructionEvents.count, displayedMessageCount, messages.count)
        return min(
            Self.maxReconstructionEventLimit,
            max(Self.initialReconstructionEventLimit, loadedDepth + Self.additionalMessageBatchSize)
        )
    }

    /// Clear state that refers to an in-flight turn (streaming text,
    /// thinking, running tools) so reconstruction can rebuild it from
    /// the event log without double-rendering.
    ///
    /// ## Scope
    ///
    /// This resets ONLY transient-turn state — the deliberate contract
    /// is that everything else survives reconnect:
    ///
    /// - `inputBarState` (text and attachments): the user
    ///   may be mid-composition; losing it on a transient reconnect
    ///   would destroy their work.
    /// - `draftStore` (persisted drafts): same reason, and these are
    ///   disk-backed anyway.
    /// - Coordinator-local caches: derived from persisted events, so
    ///   reconstruction refreshes them implicitly.
    ///
    /// ## Session switching is NOT this function's job
    ///
    /// Sessions are switched by `ContentView.navigationDestination`
    /// instantiating a new `ChatView` with `.id(sessionId)`, which
    /// forces SwiftUI to destroy the old view tree and rebuild a fresh
    /// `ChatViewModel`. Per-session state starts clean by construction;
    /// there is no single "reset everything" path here. Any new state
    /// added to `ChatViewModel` that should clear on reconstruction
    /// (not switch) belongs in THIS function — but "on switch" is
    /// handled automatically by view-model recreation.
    func cleanUpStreamingState() {
        // Capture streaming message ID before reset nulls it
        let streamingId = streamingManager.streamingMessageId
        // Before tearing the live streaming state down, snapshot the
        // streaming message UUID + accumulated text. If reconstruction's
        // in-flight state produces a streaming message that continues
        // from this snapshot, processInFlightState reuses the UUID so
        // the bubble doesn't flicker away and back with a new identity.
        // Only captured when there is actual text to preserve —
        // an empty streaming bubble has no visible state to protect.
        if let streamingId, !streamingManager.receivedText.isEmpty {
            streamingRecoverySnapshot = StreamingRecoverySnapshot(
                messageId: streamingId,
                text: streamingManager.receivedText
            )
        }
        streamingManager.reset()
        // Remove any in-flight streaming message
        if let streamingId {
            removeFromMessages { $0.id == streamingId }
        }
        // Remove in-flight thinking message (will be re-created from reconstruction)
        if let thinkingId = thinkingMessageId {
            removeFromMessages { $0.id == thinkingId }
        }
        // Remove current-turn tool messages (will be re-created from reconstruction)
        let currentTurnToolIds = currentTurnToolMessageIds
        removeFromMessages { currentTurnToolIds.contains($0.id) }
        // Clear turn tracking state
        thinkingMessageId = nil
        currentTurnToolMessageIds.removeAll()
        // Reset thinking accumulators so stale content doesn't bleed through
        thinkingState.seedCatchUpThinking("", isStreaming: false)
    }

    /// Drain events that were buffered during reconstruction.
    /// Called by ConnectionCoordinator only after reconstruction commits and
    /// sequenceHighWaterMark is set.
    ///
    /// Sort the buffered batch by `sequence` before dispatch so
    /// out-of-order arrivals (race between the reconstructed history
    /// page and live broadcast frames) replay in the canonical
    /// session-log order. Sort is **stable** so events without a
    /// sequence (transient lifecycle signals) keep their arrival
    /// order and are routed AFTER all sequenced events — they depend
    /// on session state established by the sequenced path.
    func drainEventBuffer() {
        guard !eventBuffer.isEmpty else {
            logger.debug("[RECONSTRUCT] Event buffer empty, nothing to drain", category: .session)
            return
        }
        let buffered = eventBuffer
        eventBuffer.removeAll()

        // Stable sort: sequenced events first by sequence, unsequenced
        // events retain their relative order at the end.
        // Swift's `sort(by:)` is NOT guaranteed stable; we build the
        // ordering manually with an enumerated index tiebreaker.
        let ordered = buffered
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.sequence, rhs.element.sequence) {
                case let (lSeq?, rSeq?):
                    // Both sequenced: ascending by sequence; tie by index.
                    if lSeq != rSeq { return lSeq < rSeq }
                    return lhs.offset < rhs.offset
                case (_?, nil):
                    // Sequenced before unsequenced.
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    // Both unsequenced: preserve arrival order.
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)

        logger.info(
            "[RECONSTRUCT] Draining \(ordered.count) buffered events (highWaterMark=\(sequenceHighWaterMark))",
            category: .session
        )
        for event in ordered {
            dispatchEvent(event)
        }
        logger.info("[RECONSTRUCT] Buffer drain complete, messages now \(messages.count)", category: .session)
    }

    // Note: The following methods are already defined in other extensions:
    // - setSessionProcessing(_:) in ChatViewModel+TurnLifecycleContext.swift
    // - showError(_:) in ChatViewModel.swift
    // - logVerbose/Debug/Info/Warning/Error in ChatViewModel.swift
    // ConnectionContext conformance uses those existing implementations.
}

// MARK: - Connection & Session Management

extension ChatViewModel {

    /// Reconstruct a worker-owned child session without resuming it or binding
    /// the shared transport's interactive-session context. Audit sheets are a
    /// read-only projection and must not disrupt the user's active chat.
    func reconstructReadOnlyTranscript() async -> ConnectionReconstructionOutcome {
        let outcome = await connectionCoordinator.reconstructReadOnly(
            context: self,
            eventLimit: Self.workerAuditReconstructionEventLimit
        )
        recordReconstructionOutcome(outcome)
        return outcome
    }

    /// Connect, resume, and reconstruct the session.
    ///
    /// Retryable and cancelled attempts retain the buffered live suffix; the
    /// mounted view's single connection-refresh task owns retry scheduling.
    func connectAndReconstruct() async -> ConnectionReconstructionOutcome {
        let outcome = await connectionCoordinator.connectAndReconstruct(context: self)
        recordReconstructionOutcome(outcome)
        return outcome
    }

    /// Preserve cached rows after a retryable failure while ending any stale
    /// shell-owned loading label. A later successful reconstruction advances
    /// the phase to `.authoritative` in `processReconstructionResult`.
    func recordReconstructionOutcome(_ outcome: ConnectionReconstructionOutcome) {
        guard !hasAuthoritativeHistory,
              (outcome == .retryableFailure || outcome == .terminalFailure) else { return }
        conversationHistoryPhase = .recoverableFailure(
            hasCachedTranscript: conversationHistoryPhase.showsCachedTranscript
        )
    }

}
