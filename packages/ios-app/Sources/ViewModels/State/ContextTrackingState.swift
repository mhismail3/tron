import SwiftUI

/// Manages context and token tracking state for ChatViewModel
/// Uses server-provided normalizedUsage values instead of local calculations
/// to eliminate bugs from model switches, session resume/fork, and context shrinks.
@Observable
@MainActor
final class ContextTrackingState {
    /// Total token usage for the session
    var totalTokenUsage: TokenUsage?

    /// Current model's context window size (from server's model.list)
    var currentContextWindow: Int = 200_000

    // MARK: - Server-Provided Values (from normalizedUsage)

    /// Per-turn NEW tokens (for stats line display) - from server's normalizedUsage.newInputTokens
    var newInputTokens: Int = 0

    /// Total context size in tokens (for progress pill) - from server's normalizedUsage.contextWindowTokens
    var contextWindowTokens: Int = 0

    /// Output tokens for this turn - from server's normalizedUsage.outputTokens
    var outputTokens: Int = 0

    // MARK: - Accumulated Totals (from session counters, NOT locally accumulated)

    /// Accumulated input tokens across all turns
    var accumulatedInputTokens = 0

    /// Accumulated output tokens across all turns
    var accumulatedOutputTokens = 0

    /// Accumulated cache read tokens across all turns
    var accumulatedCacheReadTokens = 0

    /// Accumulated cache creation tokens across all turns
    var accumulatedCacheCreationTokens = 0

    /// Accumulated cost across all turns
    var accumulatedCost: Double = 0

    /// Last turn's input tokens (alias for contextWindowTokens for API compatibility)
    var lastTurnInputTokens: Int {
        get { contextWindowTokens }
        set { contextWindowTokens = newValue }
    }

    init() {}

    // MARK: - Computed Properties (using server values)

    /// Estimated context usage percentage based on server-provided contextWindowTokens
    /// (which represents the actual current context size)
    var contextPercentage: Int {
        guard currentContextWindow > 0 else { return 0 }
        guard contextWindowTokens > 0 else { return 0 }

        let percentage = Double(contextWindowTokens) / Double(currentContextWindow) * 100
        return min(100, Int(percentage.rounded()))
    }

    /// Tokens remaining in the context window
    var tokensRemaining: Int {
        max(0, currentContextWindow - contextWindowTokens)
    }

    // MARK: - Server Value Updates

    /// Update from server's normalizedUsage (called on turn_end)
    /// This is the preferred method - uses server-calculated values
    func updateFromNormalizedUsage(_ usage: NormalizedTokenUsage) {
        newInputTokens = usage.newInputTokens
        contextWindowTokens = usage.contextWindowTokens
        outputTokens = usage.outputTokens
    }

    /// Accumulate tokens from a turn (for billing tracking)
    /// Note: This still accumulates locally for total display, but delta calculations use server values
    func accumulate(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cost: Double
    ) {
        accumulatedInputTokens += inputTokens
        accumulatedOutputTokens += outputTokens
        accumulatedCacheReadTokens += cacheReadTokens
        accumulatedCacheCreationTokens += cacheCreationTokens
        accumulatedCost += cost
    }

    /// Set accumulated token state from TokenUsage (used when restoring from reconstructed state)
    /// This replaces the accumulated values rather than incrementing them.
    func setAccumulatedTokens(from usage: TokenUsage) {
        accumulatedInputTokens = usage.inputTokens
        accumulatedOutputTokens = usage.outputTokens
        accumulatedCacheReadTokens = usage.cacheReadTokens ?? 0
        accumulatedCacheCreationTokens = usage.cacheCreationTokens ?? 0
    }

    /// Set totalTokenUsage for display purposes
    /// - Parameters:
    ///   - contextWindowSize: The current context window size (for progress bar)
    ///   - usage: The token usage with output/cache values
    func setTotalTokenUsage(contextWindowSize: Int, from usage: TokenUsage) {
        totalTokenUsage = TokenUsage(
            inputTokens: contextWindowSize,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheCreationTokens: usage.cacheCreationTokens
        )
    }

    /// Update context window based on available model info
    func updateContextWindow(from models: [ModelInfo], currentModel: String) {
        if let model = models.first(where: { $0.id == currentModel }) {
            currentContextWindow = model.contextWindow
        }
    }

    /// Reset all accumulated state (for new session)
    func reset() {
        totalTokenUsage = nil
        newInputTokens = 0
        contextWindowTokens = 0
        outputTokens = 0
        accumulatedInputTokens = 0
        accumulatedOutputTokens = 0
        accumulatedCacheReadTokens = 0
        accumulatedCacheCreationTokens = 0
        accumulatedCost = 0
    }
}
