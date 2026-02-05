import Foundation
import os

// MARK: - Token State Manager

/// Manages session-level token tracking state.
///
/// This provides a unified token tracking system that replaces the previous
/// fragmented tracking. It mirrors the agent-side TokenStateManager.
///
/// Key responsibilities:
/// - Recording per-turn token usage
/// - Accumulating totals for billing display
/// - Tracking context window state for progress bar
/// - Maintaining history for audit trail
/// - Supporting session resume/restore
@Observable
@MainActor
final class TokenStateManager {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tron",
        category: "TokenStateManager"
    )

    // MARK: - State

    /// Current turn's record (most recent)
    private(set) var current: TokenRecord?

    /// Accumulated totals (for billing)
    private(set) var accumulated: AccumulatedTokens

    /// Context window state
    private(set) var contextWindow: ContextWindowState

    /// History of all token records (for audit trail)
    private(set) var history: [TokenRecord] = []

    // MARK: - Initialization

    init(maxContextSize: Int = 1_000_000) {
        self.accumulated = AccumulatedTokens()
        self.contextWindow = ContextWindowState(maxSize: maxContextSize)
    }

    // MARK: - Recording

    /// Update from server's turn_end event with TokenRecord
    func updateFromTurnEnd(_ record: TokenRecord) {
        // Validate: log warning if tokens are 0
        if record.source.rawInputTokens == 0 && record.source.rawOutputTokens == 0 {
            logger.warning("[TOKEN-ANOMALY] Received zero tokens in turn_end (turn=\(record.meta.turn))")
        }

        // Update current
        current = record

        // Accumulate
        accumulated.inputTokens += record.source.rawInputTokens
        accumulated.outputTokens += record.source.rawOutputTokens
        accumulated.cacheReadTokens += record.source.rawCacheReadTokens
        accumulated.cacheCreationTokens += record.source.rawCacheCreationTokens

        // Update context window
        contextWindow.currentSize = record.computed.contextWindowTokens
        updateCalculatedValues()

        // Track history
        history.append(record)

        let contextSize = self.contextWindow.currentSize
        logger.debug("[TOKEN-STATE] Updated from turn_end: turn=\(record.meta.turn) contextWindow=\(contextSize) newInput=\(record.computed.newInputTokens)")
    }

    // MARK: - State Restoration

    /// Restore state from reconstructed events (session resume)
    func restoreFromEvents(_ records: [TokenRecord], accumulated: AccumulatedTokens) {
        self.history = records
        self.current = records.last
        self.accumulated = accumulated

        if let last = records.last {
            contextWindow.currentSize = last.computed.contextWindowTokens
        }
        updateCalculatedValues()

        let contextSize = self.contextWindow.currentSize
        logger.info("[TOKEN-RESTORE] Restored \(records.count) records, contextWindow=\(contextSize)")
    }

    /// Restore accumulated values from session data
    func setAccumulatedTokens(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cost: Double = 0
    ) {
        accumulated.inputTokens = inputTokens
        accumulated.outputTokens = outputTokens
        accumulated.cacheReadTokens = cacheReadTokens
        accumulated.cacheCreationTokens = cacheCreationTokens
        accumulated.cost = cost
    }

    /// Set context window from reconstructed state
    func setContextWindowSize(_ size: Int) {
        contextWindow.currentSize = size
        updateCalculatedValues()
    }

    // MARK: - Context Limit

    /// Set the maximum context window size (e.g., when model changes)
    func setContextLimit(_ limit: Int) {
        contextWindow.maxSize = limit
        updateCalculatedValues()
    }

    // MARK: - Cost Accumulation

    /// Add cost for a turn
    func addCost(_ cost: Double) {
        accumulated.cost += cost
    }

    // MARK: - Reset

    /// Reset all state for a new session
    func reset() {
        current = nil
        history.removeAll()
        accumulated = AccumulatedTokens()
        contextWindow = ContextWindowState(maxSize: contextWindow.maxSize)
    }

    // MARK: - Private Helpers

    private func updateCalculatedValues() {
        let maxSize = contextWindow.maxSize
        let currentSize = contextWindow.currentSize

        // Calculate percentage (cap at 100)
        let rawPercent = maxSize > 0 ? Double(currentSize) / Double(maxSize) * 100 : 0
        contextWindow.percentUsed = min(100, Int(rawPercent.rounded()))

        // Calculate tokens remaining (floor at 0)
        contextWindow.tokensRemaining = max(0, maxSize - currentSize)
    }
}

// MARK: - Supporting Types

/// Accumulated token totals across all turns in a session.
struct AccumulatedTokens {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cost: Double = 0

    var totalTokens: Int { inputTokens + outputTokens }
}

/// Current state of the context window.
struct ContextWindowState {
    var currentSize: Int = 0
    var maxSize: Int
    var percentUsed: Int = 0
    var tokensRemaining: Int

    init(maxSize: Int = 1_000_000) {
        self.maxSize = maxSize
        self.tokensRemaining = maxSize
    }
}
