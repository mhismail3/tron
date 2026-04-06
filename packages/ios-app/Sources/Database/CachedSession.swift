import Foundation

// MARK: - Cached Activity Line

/// A persisted activity line for dashboard card display.
/// Survives buffer clearing so completed session cards retain their mini-chat view.
struct CachedActivityLine: Codable, Equatable {
    let kind: String
    let text: String
    var icon: String?
    var iconColor: String?
    var displayName: String?
    var summary: String?
    var duration: String?
    var status: String?
}

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

    /// Backward compatibility: expose latestModel as model
    var model: String { latestModel }

    /// Whether session has been archived
    var isArchived: Bool { archivedAt != nil }

    // Dashboard display fields
    var lastUserPrompt: String?
    var lastAssistantResponse: String?
    var lastToolCount: Int?
    var lastActivityLines: [CachedActivityLine]?
    var isProcessing: Bool?

    /// Whether this session is a fork of another session
    var isFork: Bool?

    /// Server origin (host:port) this session was synced from
    var serverOrigin: String?

    /// Whether this is the persistent chat session
    var isChat: Bool = false

    /// Total input tokens sent to model (uncached + cache read)
    var totalInputTokens: Int { inputTokens + cacheReadTokens }

    var totalTokens: Int { totalInputTokens + outputTokens }

    var formattedTokens: String {
        TokenFormatter.formatPair(input: totalInputTokens, output: outputTokens)
    }

    /// Formatted cache tokens - separate read/creation for visibility
    var formattedCacheTokens: String? {
        if cacheReadTokens == 0 && cacheCreationTokens == 0 { return nil }
        return "⚡\(cacheReadTokens.formattedTokenCount) read, ✏\(cacheCreationTokens.formattedTokenCount) write"
    }

    /// Formatted cost string (e.g., "$0.12")
    var formattedCost: String {
        if cost < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", cost)
    }

    var displayTitle: String {
        if let title = title, !title.isEmpty {
            return title
        }
        if isChat {
            return "Chat"
        }
        return URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    var formattedDate: String {
        DateParser.formatRelativeOrAbsolute(lastActivityAt)
    }

    var shortModel: String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
