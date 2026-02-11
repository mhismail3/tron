import Foundation

// MARK: - Token Record

/// Immutable token record from a single turn.
/// Mirrors the agent-side TokenRecord structure for clean JSON parsing.
///
/// This structure preserves the full audit trail from provider API response
/// through normalization, enabling debugging and verification.
struct TokenRecord: Codable, Equatable {
    /// Source values directly from provider (immutable)
    let source: TokenSource

    /// Computed values derived from source
    let computed: ComputedTokens

    /// Metadata about this record
    let meta: TokenMeta
}

// MARK: - Token Source

/// Raw token values extracted from provider API response.
/// These are the values exactly as reported by the LLM provider.
struct TokenSource: Codable, Equatable {
    /// Provider that generated these tokens
    let provider: String

    /// ISO8601 timestamp when extracted from API response
    let timestamp: String

    /// Raw input tokens as reported by provider
    let rawInputTokens: Int

    /// Raw output tokens as reported by provider
    let rawOutputTokens: Int

    /// Tokens read from cache (Anthropic/OpenAI)
    let rawCacheReadTokens: Int

    /// Tokens written to cache (Anthropic only) - billing indicator, NOT context!
    let rawCacheCreationTokens: Int
}

// MARK: - Computed Tokens

/// Computed token values derived from source values.
/// These provide semantic clarity for different UI components.
struct ComputedTokens: Codable, Equatable {
    /// Total context window size in tokens (for progress bar)
    /// Anthropic: inputTokens + cacheReadTokens
    /// Others: inputTokens
    let contextWindowTokens: Int

    /// Per-turn NEW tokens (for stats line display)
    /// First turn: equals contextWindowTokens
    /// Subsequent: contextWindowTokens - previousContextBaseline
    let newInputTokens: Int

    /// Baseline used for delta calculation
    let previousContextBaseline: Int

    /// Method used for context window calculation
    let calculationMethod: String
}

// MARK: - Token Meta

/// Metadata about a token record for audit trail.
struct TokenMeta: Codable, Equatable {
    /// Turn number within the session
    let turn: Int

    /// Session ID this record belongs to
    let sessionId: String

    /// ISO8601 timestamp when tokens were extracted from API
    let extractedAt: String

    /// ISO8601 timestamp when normalization was computed
    let normalizedAt: String
}

// MARK: - Extensions

extension TokenSource {
    /// Total tokens (input + output)
    var totalTokens: Int { rawInputTokens + rawOutputTokens }
}

// MARK: - Display Formatting Extensions

extension TokenRecord {
    /// Formatted new input tokens (delta for stats line)
    var formattedNewInput: String { computed.newInputTokens.formattedTokenCount }

    /// Formatted output tokens
    var formattedOutput: String { source.rawOutputTokens.formattedTokenCount }

    /// Formatted context window tokens
    var formattedContextWindow: String { computed.contextWindowTokens.formattedTokenCount }

    /// Formatted cache read tokens, nil if zero
    var formattedCacheRead: String? {
        guard source.rawCacheReadTokens > 0 else { return nil }
        return source.rawCacheReadTokens.formattedTokenCount
    }

    /// Formatted cache creation tokens, nil if zero
    var formattedCacheWrite: String? {
        guard source.rawCacheCreationTokens > 0 else { return nil }
        return source.rawCacheCreationTokens.formattedTokenCount
    }

    /// Combined cache tokens for simplified display (read + write)
    var formattedCache: String? {
        let total = source.rawCacheReadTokens + source.rawCacheCreationTokens
        guard total > 0 else { return nil }
        return total.formattedTokenCount
    }

    /// Check if there's any cache activity to display
    var hasCacheActivity: Bool {
        source.rawCacheReadTokens > 0 || source.rawCacheCreationTokens > 0
    }
}
