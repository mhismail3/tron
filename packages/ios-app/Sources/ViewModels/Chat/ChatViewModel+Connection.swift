import Foundation
import SwiftUI

// MARK: - ConnectionContext Conformance

extension ChatViewModel: ConnectionContext {

    var isConnected: Bool {
        rpcClient.isConnected
    }

    func connect() async {
        await rpcClient.connect()
    }

    func disconnect() async {
        await rpcClient.disconnect()
    }

    func resumeSession(sessionId: String) async throws {
        try await rpcClient.session.resume(sessionId: sessionId)
    }

    func reconstructSession(sessionId: String, limit: Int?, beforeSequence: Int64?) async throws -> SessionReconstructResult {
        try await rpcClient.session.reconstruct(sessionId: sessionId, limit: limit, beforeSequence: beforeSequence)
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
    /// - `inputBarState` (text, selectedSkills, attachments): the user
    ///   may be mid-composition; losing it on a transient reconnect
    ///   would destroy their work.
    /// - `draftStore` (persisted drafts): same reason, and these are
    ///   disk-backed anyway.
    /// - `displayStreamState`: driven by server events; the server
    ///   re-emits on reconnect.
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
        // Remove running tool messages (will be re-created from reconstruction)
        let runningToolIds = currentToolMessages.keys
        removeFromMessages { runningToolIds.contains($0.id) }
        // Clear turn tracking state
        thinkingMessageId = nil
        currentTurnToolCalls.removeAll()
        currentToolMessages.removeAll()
        // Reset thinking accumulators so stale content doesn't bleed through
        thinkingState.seedCatchUpThinking("", isStreaming: false)
    }

    /// Drain events that were buffered during reconstruction.
    /// Called by ConnectionCoordinator after reconstruction completes and
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
    // - showErrorAlert(_:) in ChatViewModel.swift
    // - logVerbose/Debug/Info/Warning/Error in ChatViewModel.swift
    // ConnectionContext conformance uses those existing implementations.
}

// MARK: - Test Support

extension ChatViewModel {

    /// Route an event through the buffer/dispatch pipeline. Test-only entry point.
    func handleEventForTesting(_ event: ParsedEventV2) {
        handleEventV2(event)
    }

    /// Number of events currently buffered during reconstruction.
    var eventBufferCount: Int { eventBuffer.count }
}

// MARK: - Connection & Session Management

extension ChatViewModel {

    /// Connect, resume, and reconstruct the session
    func connectAndReconstruct() async {
        await connectionCoordinator.connectAndReconstruct(context: self)
    }

    /// Reconnect to server and reconstruct session state
    func reconnectAndReconstruct() async {
        await connectionCoordinator.reconnectAndReconstruct(context: self)
    }
}
