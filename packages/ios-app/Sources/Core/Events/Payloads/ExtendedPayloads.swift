import Foundation

// MARK: - Metadata Payloads

/// Payload for metadata.update event
/// Server: MetadataUpdateEvent.payload
struct MetadataUpdatePayload {
    let key: String
    let previousValue: Any?
    let newValue: Any?

    init?(from payload: [String: AnyCodable]) {
        guard let key = payload.string("key") else {
            return nil
        }
        self.key = key
        self.previousValue = payload["previousValue"]?.value
        self.newValue = payload["newValue"]?.value
    }
}

/// Payload for metadata.tag event
/// Server: MetadataTagEvent.payload
struct MetadataTagPayload {
    let action: String  // "add" | "remove"
    let tag: String

    init?(from payload: [String: AnyCodable]) {
        guard let action = payload.string("action"),
              let tag = payload.string("tag") else {
            return nil
        }
        self.action = action
        self.tag = tag
    }
}

// MARK: - File Payloads

/// Payload for file.read event
/// Server: FileReadEvent.payload
struct FileReadPayload {
    let path: String
    let linesStart: Int?
    let linesEnd: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path") else {
            return nil
        }
        self.path = path

        if let lines = payload.dict("lines") {
            self.linesStart = lines["start"] as? Int
            self.linesEnd = lines["end"] as? Int
        } else {
            self.linesStart = nil
            self.linesEnd = nil
        }
    }
}

/// Payload for file.write event
/// Server: `events/types/payloads/file.rs::FileWritePayload`
///
/// All three fields (`path`, `size`, `contentHash`) are required on the wire —
/// the Rust struct declares them as non-optional (`path: String`,
/// `size: i64`, `content_hash: String`). Missing any of them fails decoding
/// (`return nil`) rather than silently substituting a default that would
/// lie about the file's recorded size.
struct FileWritePayload {
    let path: String
    let size: Int
    let contentHash: String

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let size = payload.int("size"),
              let contentHash = payload.string("contentHash") else {
            TronLogger.shared.warning(
                "file.write event missing required field(s) path/size/contentHash; dropping",
                category: .events
            )
            return nil
        }
        self.path = path
        self.size = size
        self.contentHash = contentHash
    }
}

/// Payload for file.edit event
/// Server: FileEditEvent.payload
struct FileEditPayload {
    let path: String
    let oldString: String
    let newString: String
    let diff: String?

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let oldString = payload.string("oldString"),
              let newString = payload.string("newString") else {
            return nil
        }
        self.path = path
        self.oldString = oldString
        self.newString = newString
        self.diff = payload.string("diff")
    }
}

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

// MARK: - Context Snapshot Payloads

/// Parameters for context.getSnapshot engine protocol method
struct ContextGetSnapshotParams: Codable {
    let sessionId: String
}

/// Result from context.getSnapshot engine protocol method
struct ContextSnapshotResult: Codable {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String
    /// Whether this is a local (Ollama) model session.
    let isLocalModel: Bool?
    let breakdown: ContextBreakdown

    struct ContextBreakdown: Codable {
        let systemPrompt: Int
        let capabilities: Int
        let environment: Int
        let messages: Int
        let providerAdjustment: Int?
    }
}

/// Parameters for context.clear engine protocol method
struct ContextClearParams: Codable {
    let sessionId: String
}

/// Result from context.clear engine protocol method
struct ContextClearResult: Codable {
    let success: Bool
    let tokensBefore: Int
    let tokensAfter: Int
}

/// Parameters for context.compact engine protocol method
struct ContextCompactParams: Codable {
    let sessionId: String
}

/// Result from context.compact engine protocol method
struct ContextCompactResult: Codable {
    let success: Bool
    let tokensBefore: Int
    let tokensAfter: Int
}

/// Detailed message info for context auditing
struct DetailedMessageInfo: Codable, Identifiable {
    let index: Int
    let role: String  // "user" | "assistant" | "capability_result"
    let tokens: Int
    let summary: String
    let content: String
    let capabilityInvocations: [CapabilityInvocationInfo]?
    let invocationId: String?
    let isError: Bool?
    /// Event ID for this message (for deletion support) - nil for synthetic messages
    let eventId: String?

    var id: Int { index }

    struct CapabilityInvocationInfo: Codable, Identifiable {
        let id: String
        let name: String
        let tokens: Int
        let arguments: String
    }
}

/// Environment metadata for a session.
struct EnvironmentInfo: Codable {
    let workingDirectory: String?
    let serverOrigin: String?
}

/// Capability name and brief description for the context audit capabilities list.
struct CapabilitySummaryInfo: Codable, Identifiable {
    let name: String
    let description: String
    var id: String { name }
}

/// Result from context.getDetailedSnapshot engine protocol method
struct DetailedContextSnapshotResult: Codable {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String
    /// Whether this is a local (Ollama) model session.
    let isLocalModel: Bool?
    let breakdown: ContextSnapshotResult.ContextBreakdown
    let messages: [DetailedMessageInfo]
    /// Effective system-level context sent to the model
    let systemPromptContent: String
    /// Raw capability clarification content if applicable (for debugging)
    let capabilityClarificationContent: String?
    let capabilitiesContent: [CapabilitySummaryInfo]
    /// Full composed system prompt as sent to the LLM (single source of truth via compose_context_parts)
    let composedSystemPrompt: String?
    /// Environment metadata (working directory, server origin)
    let environment: EnvironmentInfo?
}
