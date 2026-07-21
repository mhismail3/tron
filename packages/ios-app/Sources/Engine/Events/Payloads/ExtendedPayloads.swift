import Foundation

// MARK: - Compaction Payloads

/// Payload for compact.boundary event
/// Server: `events/types/payloads/compact.rs::CompactBoundaryPayload`
///
/// `originalTokens`, `compactedTokens`, and `reason` are required on the
/// wire. The Rust struct declares `deny_unknown_fields` and no defaults,
/// so iOS mirrors that contract: missing any required field fails the
/// decode (`return nil`) rather than silently substituting a default.
struct CompactBoundaryPayload {
    let rangeFrom: String?
    let rangeTo: String?
    let originalTokens: Int
    let compactedTokens: Int
    /// Non-empty trigger label matching `CompactionReason` serde
    /// serialization (snake_case): "manual", "threshold_exceeded",
    /// "progress_signal", or "imported" for events emitted by the
    /// import transformer.
    let reason: String
    let summary: String?
    let estimatedContextTokens: Int?
    let preservedTurns: Int?
    let summarizedTurns: Int?
    let preservedMessages: Int?

    init?(from payload: [String: AnyCodable]) {
        // Range fields are optional (not present in auto-compaction events)
        if let range = payload.dict("range") {
            self.rangeFrom = range["from"] as? String
            self.rangeTo = range["to"] as? String
        } else {
            self.rangeFrom = nil
            self.rangeTo = nil
        }

        // Token counts are required
        guard let originalTokens = payload.int("originalTokens"),
              let compactedTokens = payload.int("compactedTokens") else {
            return nil
        }
        self.originalTokens = originalTokens
        self.compactedTokens = compactedTokens

        // Reason is required. The server emits it at every
        // production site and the import transformer tags historical
        // boundaries as `"imported"`.
        guard let reason = payload.string("reason"), !reason.isEmpty else {
            return nil
        }
        self.reason = reason

        // Summary is optional (may not be present in auto-compaction events)
        self.summary = payload.string("summary")

        // Estimated total context tokens after compaction (system + capabilities + environment + messages)
        self.estimatedContextTokens = payload.int("estimatedContextTokens")

        // Turn counts from turn-based compaction
        self.preservedTurns = payload.int("preservedTurns")
        self.summarizedTurns = payload.int("summarizedTurns")
        self.preservedMessages = payload.int("preservedMessages")
    }
}

/// Payload for context.cleared event
/// Server: ContextClearedEvent.payload
struct ContextClearedPayload {
    let tokensBefore: Int
    let tokensAfter: Int

    init?(from payload: [String: AnyCodable]) {
        guard let tokensBefore = payload.int("tokensBefore"),
              let tokensAfter = payload.int("tokensAfter") else {
            return nil
        }
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }
}
