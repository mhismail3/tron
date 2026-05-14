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

        // Estimated total context tokens after compaction (system + capabilities + rules + messages)
        self.estimatedContextTokens = payload.int("estimatedContextTokens")

        // Turn counts from turn-based compaction
        self.preservedTurns = payload.int("preservedTurns")
        self.summarizedTurns = payload.int("summarizedTurns")
        self.preservedMessages = payload.int("preservedMessages")
    }
}

/// Payload for compact.summary event
/// Server: CompactSummaryEvent.payload
struct CompactSummaryPayload {
    let summary: String
    let keyDecisions: [String]?
    let filesModified: [String]?
    let boundaryEventId: String

    init?(from payload: [String: AnyCodable]) {
        guard let summary = payload.string("summary"),
              let boundaryEventId = payload.string("boundaryEventId") else {
            return nil
        }
        self.summary = summary
        self.boundaryEventId = boundaryEventId
        self.keyDecisions = payload.stringArray("keyDecisions")
        self.filesModified = payload.stringArray("filesModified")
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

// MARK: - Skill Compaction Payloads

/// Render mode carried on `skills.cleared` events.
///
/// Mirrors the Rust `SkillsClearedMode` enum in
/// `packages/agent/src/events/types/payloads/skill.rs`. The discriminator tells
/// iOS how to render the pill:
///
/// - `.clearAll`: informational banner listing the cleared skill names. The
///   user can re-activate manually via `@skill-name` mention or the sidebar.
/// - `.userInteraction`: interactive picker — each cleared skill becomes a tappable
///   chip that re-adds it via the `skills::activate` engine protocol.
///
/// Wire format is lowerCamelCase (`"clearAll"` / `"userInteraction"`).
enum SkillsClearedMode: String, Codable, Equatable, Hashable {
    case clearAll
    case userInteraction
}

/// Payload for `skills.cleared` event.
///
/// Server: `SkillsClearedPayload` in `events/types/payloads/skill.rs`. Emitted
/// on the first prompt after a `compact.boundary` under either ClearAll or
/// UserInteraction compaction policy; AutoRestore never emits this event because it
/// preserves active skills through the boundary.
///
/// All three fields (`clearedSkills`, `reason`, `mode`) are required on the
/// wire. The server emits them unconditionally and enforces
/// `deny_unknown_fields`. Missing fields here fail decoding (`return nil`)
/// rather than falling back to defaults that would mis-render the event.
struct SkillsClearedPayload {
    /// Names of the skills that were active at the boundary and are now
    /// cleared. May be empty only in pathological cases (concurrent
    /// re-activation); the server suppresses emission when the set is empty.
    let clearedSkills: [String]
    /// Always `"compaction"` today. Reserved for future reasons.
    let reason: String
    /// Render mode — see `SkillsClearedMode`.
    let mode: SkillsClearedMode

    init?(from payload: [String: AnyCodable]) {
        guard let clearedSkills = payload.stringArray("clearedSkills") else {
            return nil
        }
        guard let reason = payload.string("reason") else {
            return nil
        }
        guard let rawMode = payload.string("mode"),
              let mode = SkillsClearedMode(rawValue: rawMode) else {
            return nil
        }
        self.clearedSkills = clearedSkills
        self.reason = reason
        self.mode = mode
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
        let rules: Int
        let memory: Int
        let skillIndex: Int
        let skillContext: Int
        let skillRemoval: Int
        let jobResults: Int
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
    /// Skills explicitly added to this session's context
    let addedSkills: [AddedSkillInfo]
    /// Rules files loaded for this session (immutable, cannot be removed)
    let rules: LoadedRules?
    /// User-memory file (MEMORY.md + rules/ listing) auto-injected into the
    /// LLM context every turn. Server-side: `runtime::memory::MemoryRegistry`.
    let memory: UserMemorySnapshot?
    /// Session memories written during this session (auto or manual ledger)
    let sessionMemories: LoadedMemory?
    /// Task context summary (if tasks exist)
    let taskContext: LoadedTaskContext?
    /// Full composed system prompt as sent to the LLM (single source of truth via compose_context_parts)
    let composedSystemPrompt: String?
    /// Environment metadata (working directory, server origin)
    let environment: EnvironmentInfo?
}

/// A single auto-injected memory entry
struct LoadedMemoryEntry: Codable, Identifiable {
    let title: String
    let content: String

    var id: String { title }
}

/// Memory auto-injected at session start
struct LoadedMemory: Codable {
    let count: Int
    let tokens: Int
    let entries: [LoadedMemoryEntry]?
}

/// User-memory wire format. Server populates this every turn from
/// `~/.tron/memory/MEMORY.md` + the listing of `rules/*.md`.
///
/// See `runtime::memory::MemoryRegistry` for the load path and
/// `Views/AgentControl/MemorySection.swift` for the UI that renders it.
struct UserMemorySnapshot: Codable, Equatable {
    /// Full content string injected into the LLM system prompt. When
    /// `bootstrapped == false`, this is the server-generated bootstrap stub.
    let content: String
    /// Listing of `rules/*.md` files (not contents). Agent reads individual
    /// files on demand via the `filesystem::read_file` capability.
    let ruleFiles: [UserMemoryRuleFile]
    /// True iff `MEMORY.md` exists on disk at read time.
    let bootstrapped: Bool
}

/// One entry in the user-memory `rules/` listing.
struct UserMemoryRuleFile: Codable, Equatable, Identifiable {
    /// Filename relative to `rules/` (e.g. `"user-preferences.md"`).
    let name: String
    /// Single-line description from YAML frontmatter, if present.
    let description: String?

    var id: String { name }
}

/// Task context summary auto-injected into LLM context
struct LoadedTaskContext: Codable {
    let summary: String
    let tokens: Int
}

// MARK: - Worktree Payloads
//
// Worktree events (`worktree.acquired` / `.commit` / `.released` / `.merged` /
// `.renamed`) are consumed in two places:
//
// - Live streaming: the per-event plugins in
//   `Core/Events/Plugins/Worktree/` decode directly into each plugin's own
//   `EventData.DataPayload`.
// - History reconstruction: `UnifiedEventTransformer.handleWorktreeEvent`
//   reads the payload dict inline with strict guards and drops malformed
//   events.
//
// There is no shared wrapper struct here on purpose — an unused
// `WorktreeAcquiredPayload` / `...Commit` / `...Released` / `...Merged` type
// lived in this file previously and drifted out of sync with the server
// schema. If a third consumer appears, add a strict `init?(from:)` type at
// that point rather than resurrecting the speculative shared version.
