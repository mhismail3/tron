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

    /// Server-authoritative pricing status and cost breakdown
    let pricing: PricingRecord

    init(
        source: TokenSource,
        computed: ComputedTokens,
        meta: TokenMeta,
        pricing: PricingRecord = .unavailable(model: "unknown", reason: "test_unavailable")
    ) {
        self.source = source
        self.computed = computed
        self.meta = meta
        self.pricing = pricing
    }
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

    /// Provider-native cached input tokens
    let rawCachedInputTokens: Int

    /// Tokens written to cache
    let rawCacheCreationTokens: Int

    /// 5-minute TTL cache creation tokens
    let rawCacheCreation5mTokens: Int

    /// 1-hour TTL cache creation tokens
    let rawCacheCreation1hTokens: Int

    /// Hidden reasoning output tokens
    let rawReasoningOutputTokens: Int

    /// Provider thinking tokens
    let rawThoughtTokens: Int

    /// Tool-use prompt tokens
    let rawToolUsePromptTokens: Int

    /// Provider-reported total token count
    let rawTotalTokens: Int

    init(
        provider: String,
        timestamp: String,
        rawInputTokens: Int,
        rawOutputTokens: Int,
        rawCacheReadTokens: Int,
        rawCacheCreationTokens: Int,
        rawCachedInputTokens: Int = 0,
        rawCacheCreation5mTokens: Int = 0,
        rawCacheCreation1hTokens: Int = 0,
        rawReasoningOutputTokens: Int = 0,
        rawThoughtTokens: Int = 0,
        rawToolUsePromptTokens: Int = 0,
        rawTotalTokens: Int? = nil
    ) {
        self.provider = provider
        self.timestamp = timestamp
        self.rawInputTokens = rawInputTokens
        self.rawOutputTokens = rawOutputTokens
        self.rawCacheReadTokens = rawCacheReadTokens
        self.rawCachedInputTokens = rawCachedInputTokens
        self.rawCacheCreationTokens = rawCacheCreationTokens
        self.rawCacheCreation5mTokens = rawCacheCreation5mTokens
        self.rawCacheCreation1hTokens = rawCacheCreation1hTokens
        self.rawReasoningOutputTokens = rawReasoningOutputTokens
        self.rawThoughtTokens = rawThoughtTokens
        self.rawToolUsePromptTokens = rawToolUsePromptTokens
        self.rawTotalTokens = rawTotalTokens ?? (
            rawInputTokens + rawOutputTokens + rawCacheReadTokens + rawCacheCreationTokens
        )
    }
}

// MARK: - Computed Tokens

/// Computed token values derived from source values.
/// These provide semantic clarity for different UI components.
struct ComputedTokens: Codable, Equatable {
    /// Total context window size in tokens (for progress bar)
    /// Anthropic: inputTokens + cacheReadTokens + cacheCreationTokens
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

    /// Model used for this provider call
    let model: String

    /// Context segment identifier used for baseline resets
    let contextSegmentId: String

    /// Baseline reset reason, or "none"
    let baselineResetReason: String

    /// ISO8601 timestamp when tokens were extracted from API
    let extractedAt: String

    /// ISO8601 timestamp when normalization was computed
    let normalizedAt: String

    init(
        turn: Int,
        sessionId: String,
        model: String = "unknown",
        contextSegmentId: String? = nil,
        baselineResetReason: String = "none",
        extractedAt: String,
        normalizedAt: String
    ) {
        self.turn = turn
        self.sessionId = sessionId
        self.model = model
        self.contextSegmentId = contextSegmentId ?? "\(sessionId):\(model)"
        self.baselineResetReason = baselineResetReason
        self.extractedAt = extractedAt
        self.normalizedAt = normalizedAt
    }
}

// MARK: - Pricing

struct PricingRecord: Codable, Equatable {
    let available: Bool
    let model: String
    let reason: String?
    let cost: TokenCostBreakdown?

    static func unavailable(model: String, reason: String) -> PricingRecord {
        PricingRecord(available: false, model: model, reason: reason, cost: nil)
    }
}

struct TokenCostBreakdown: Codable, Equatable {
    let baseInputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let baseInputCost: Double
    let outputCost: Double
    let cacheReadCost: Double
    let cacheWriteCost: Double
    let totalCost: Double
    let currency: String
}

// MARK: - Dictionary Parsing

extension TokenRecord {
    /// Parse a TokenRecord from a raw dictionary (event payload format).
    /// Returns nil if the dict is nil or missing required source/computed/meta sections.
    static func from(dict: [String: Any]?) -> TokenRecord? {
        guard let dict,
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let record = try? JSONDecoder().decode(TokenRecord.self, from: data) else {
            return nil
        }
        return record
    }
}

// MARK: - Extensions

extension TokenSource {
    /// Provider-reported total tokens.
    var totalTokens: Int { rawTotalTokens }
}

// MARK: - Display Formatting Extensions

extension TokenRecord {
    /// Formatted provider-reported input tokens.
    var formattedInput: String { source.rawInputTokens.formattedTokenCount }

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
