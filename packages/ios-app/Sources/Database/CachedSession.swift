import Foundation

// MARK: - Cached Session

/// Session metadata cached locally
struct CachedSession: Identifiable, Codable {
    let id: String
    let workspaceId: String
    var rootEventId: String?
    var headEventId: String?
    var title: String?
    var latestModel: String
    var workingDirectory: String
    var createdAt: String
    var lastActivityAt: String
    /// Whether session has been archived (derived from archived_at IS NOT NULL)
    var archivedAt: String?
    var eventCount: Int
    var messageCount: Int
    var inputTokens: Int
    var outputTokens: Int
    /// Current context size (input_tokens from last API call)
    var lastTurnInputTokens: Int
    /// Total tokens read from prompt cache
    var cacheReadTokens: Int = 0
    /// Total tokens written to prompt cache
    var cacheCreationTokens: Int = 0
    var cost: Double

    /// Whether session has been archived
    var isArchived: Bool { archivedAt != nil }

    // Dashboard display fields
    var lastUserPrompt: String?
    var lastAssistantResponse: String?
    var lastActivityLines: [ActivityLine]?
    var isProcessing: Bool?

    /// Whether this session is a fork of another session
    var isFork: Bool?

    /// Server origin (host:port) this session was synced from
    var serverOrigin: String?

    /// Whether this session is pending server deletion
    var isDeleting: Bool = false

    /// Whether this is the persistent chat session
    var isChat: Bool = false

    /// Total input tokens sent to model (uncached + cache read)
    var totalInputTokens: Int { inputTokens + cacheReadTokens }

    var totalTokens: Int { totalInputTokens + outputTokens }
}
