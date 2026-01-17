import SwiftUI

/// Manages context and token tracking state for ChatViewModel
/// Extracted from ChatViewModel to reduce property sprawl
@Observable
@MainActor
final class ContextTrackingState {
    /// Total token usage for the session
    var totalTokenUsage: TokenUsage?

    /// Current model's context window size (from server's model.list)
    var currentContextWindow: Int = 200_000

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

    /// Last turn's input tokens (represents actual current context size)
    var lastTurnInputTokens = 0

    /// Previous turn's final input tokens (for computing incremental delta)
    var previousTurnFinalInputTokens = 0

    init() {}

    /// Estimated context usage percentage based on last turn's input tokens
    /// (which represents the actual current context size sent to the LLM)
    var contextPercentage: Int {
        guard currentContextWindow > 0 else { return 0 }
        guard lastTurnInputTokens > 0 else { return 0 }

        let percentage = Double(lastTurnInputTokens) / Double(currentContextWindow) * 100
        return min(100, Int(percentage.rounded()))
    }

    /// The incremental token delta from the previous turn
    var tokenDelta: Int {
        lastTurnInputTokens - previousTurnFinalInputTokens
    }

    /// Accumulate tokens from a turn
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

    /// Record the end of a turn (updates previous turn tokens for delta calculation)
    func recordTurnEnd() {
        previousTurnFinalInputTokens = lastTurnInputTokens
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
        accumulatedInputTokens = 0
        accumulatedOutputTokens = 0
        accumulatedCacheReadTokens = 0
        accumulatedCacheCreationTokens = 0
        accumulatedCost = 0
        lastTurnInputTokens = 0
        previousTurnFinalInputTokens = 0
    }
}
