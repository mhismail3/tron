import Foundation

// MARK: - JSON-RPC Base Types

/// JSON-RPC 2.0 style request wrapper
struct RPCRequest<P: Encodable>: Encodable {
    let id: String
    let method: String
    let params: P

    init(method: String, params: P) {
        self.id = UUID().uuidString
        self.method = method
        self.params = params
    }
}

/// JSON-RPC response wrapper
struct RPCResponse<R: Decodable>: Decodable {
    let id: String
    let success: Bool
    let result: R?
    let error: RPCError?
}

/// RPC error details
struct RPCError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let details: [String: AnyCodable]?

    var errorDescription: String? { message }
}

/// Empty params for methods that don't require parameters
struct EmptyParams: Codable {}

// MARK: - Session Methods

struct SessionCreateParams: Encodable {
    let workingDirectory: String
    let model: String?
    let contextFiles: [String]?

    init(workingDirectory: String, model: String? = nil, contextFiles: [String]? = nil) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.contextFiles = contextFiles
    }
}

struct SessionCreateResult: Decodable {
    let sessionId: String
    let model: String
    let createdAt: String
}

struct SessionListParams: Encodable {
    let workingDirectory: String?
    let limit: Int?
    let includeEnded: Bool?
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let sessionId: String
    let model: String
    let createdAt: String
    let messageCount: Int
    let isActive: Bool
    let workingDirectory: String?

    var id: String { sessionId }

    var displayName: String {
        if let dir = workingDirectory {
            return URL(fileURLWithPath: dir).lastPathComponent
        }
        return sessionId.prefix(8).description
    }

    var formattedDate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) {
            let relativeFormatter = RelativeDateTimeFormatter()
            relativeFormatter.unitsStyle = .abbreviated
            return relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return createdAt
    }
}

struct SessionListResult: Decodable {
    let sessions: [SessionInfo]
}

struct SessionResumeParams: Encodable {
    let sessionId: String
}

struct SessionResumeResult: Decodable {
    let sessionId: String
    let model: String
    let messageCount: Int
    let lastActivity: String
}

struct SessionEndParams: Encodable {
    let sessionId: String
}

struct SessionHistoryParams: Encodable {
    let sessionId: String
    let limit: Int?
    let beforeId: String?
}

struct HistoryMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String
    let timestamp: String
    let toolUse: [ToolUseInfo]?
}

struct ToolUseInfo: Decodable {
    let toolName: String
    let toolCallId: String
    let input: [String: AnyCodable]?
    let result: String?
    let isError: Bool?
}

struct SessionHistoryResult: Decodable {
    let messages: [HistoryMessage]
    let hasMore: Bool
}

// MARK: - Agent Methods

struct AgentPromptParams: Encodable {
    let sessionId: String
    let prompt: String
    let images: [ImageAttachment]?

    init(sessionId: String, prompt: String, images: [ImageAttachment]? = nil) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.images = images
    }
}

struct ImageAttachment: Encodable {
    let data: String  // base64 encoded
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
    }
}

struct AgentPromptResult: Decodable {
    let acknowledged: Bool
}

struct AgentAbortParams: Encodable {
    let sessionId: String
}

struct AgentStateParams: Encodable {
    let sessionId: String
}

/// Tool call info for in-progress turn (for resume support)
struct CurrentTurnToolCall: Decodable {
    let toolCallId: String
    let toolName: String
    let arguments: [String: AnyCodable]?
    let status: String  // "pending" | "running" | "completed" | "error"
    let result: String?
    let isError: Bool?
    let startedAt: String
    let completedAt: String?
}

struct AgentStateResult: Decodable {
    let isRunning: Bool
    let currentTurn: Int
    let messageCount: Int
    let tokenUsage: AgentStateTokenUsage?
    let model: String
    let tools: [String]?  // Server returns this but we don't need it
    /// Accumulated text from current in-progress turn (for resume)
    let currentTurnText: String?
    /// Tool calls from current in-progress turn (for resume)
    let currentTurnToolCalls: [CurrentTurnToolCall]?
    /// Whether the session was interrupted (last assistant message has interrupted flag)
    let wasInterrupted: Bool?
}

/// Token usage specifically for agent.getState response (uses different field names)
struct AgentStateTokenUsage: Decodable {
    let input: Int
    let output: Int

    var totalTokens: Int { input + output }
}

struct TokenUsage: Decodable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?

    var totalTokens: Int { inputTokens + outputTokens }

    var formattedInput: String { formatTokenCount(inputTokens) }
    var formattedOutput: String { formatTokenCount(outputTokens) }
    var formattedTotal: String { formatTokenCount(totalTokens) }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - System Methods

struct SystemInfoResult: Decodable {
    let version: String
    let uptime: Int
    let activeSessions: Int
}

struct SystemPingResult: Decodable {
    let pong: Bool
}

// MARK: - Session Delete/Fork/Rewind

struct SessionDeleteParams: Encodable {
    let sessionId: String
}

struct SessionDeleteResult: Decodable {
    let deleted: Bool
}

struct SessionForkParams: Encodable {
    let sessionId: String
    let fromEventId: String?  // Event ID to fork from (nil = fork from HEAD)
}

struct SessionForkResult: Decodable {
    let newSessionId: String
    let forkedFromEventId: String?  // The event that was forked from
    let forkedFromSessionId: String?  // The source session
    let rootEventId: String?  // The fork event in the new session
}

struct SessionRewindParams: Encodable {
    let sessionId: String
    let toEventId: String  // Event ID to rewind to
}

struct SessionRewindResult: Decodable {
    let sessionId: String
    let newHeadEventId: String  // The new HEAD after rewind
    let previousHeadEventId: String?  // The previous HEAD before rewind
}

// MARK: - Model Methods

struct ModelSwitchParams: Encodable {
    let sessionId: String
    let model: String
}

struct ModelSwitchResult: Decodable {
    let previousModel: String
    let newModel: String
}

struct ModelInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let contextWindow: Int
    let maxOutputTokens: Int?
    let supportsThinking: Bool?
    let supportsImages: Bool?
    let tier: String?
    let isLegacy: Bool?

    /// Properly formatted display name (e.g., "Claude Opus 4.5", "Claude Sonnet 4")
    var displayName: String {
        formattedModelName
    }

    var shortName: String {
        if id.contains("opus") { return "Opus" }
        if id.contains("sonnet") { return "Sonnet" }
        if id.contains("haiku") { return "Haiku" }
        return name
    }

    /// Formats model name properly: "Claude Opus 4.5", "Claude Sonnet 4", etc.
    var formattedModelName: String {
        let lowerId = id.lowercased()

        // Detect tier
        let tierName: String
        if lowerId.contains("opus") {
            tierName = "Opus"
        } else if lowerId.contains("sonnet") {
            tierName = "Sonnet"
        } else if lowerId.contains("haiku") {
            tierName = "Haiku"
        } else {
            return name
        }

        // Detect version - check for 4.5 first (latest)
        if lowerId.contains("4-5") || lowerId.contains("4.5") {
            return "Claude \(tierName) 4.5"
        }
        // Check for version 4
        if lowerId.contains("-4-") || lowerId.contains("sonnet-4") || lowerId.contains("opus-4") || lowerId.contains("haiku-4") {
            return "Claude \(tierName) 4"
        }
        // Check for 3.5
        if lowerId.contains("3-5") || lowerId.contains("3.5") {
            return "Claude \(tierName) 3.5"
        }
        // Check for version 3
        if lowerId.contains("-3-") || lowerId.contains("sonnet-3") || lowerId.contains("opus-3") || lowerId.contains("haiku-3") {
            return "Claude \(tierName) 3"
        }

        return "Claude \(tierName)"
    }

    /// Whether this is a 4.5 (latest generation) model
    var is45Model: Bool {
        let lowerId = id.lowercased()
        return lowerId.contains("4-5") || lowerId.contains("4.5")
    }
}

struct ModelListResult: Decodable {
    let models: [ModelInfo]
}

// MARK: - Filesystem Methods

struct FilesystemListDirParams: Encodable {
    let path: String?
    let showHidden: Bool?
}

struct DirectoryEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool?
    let size: Int?
    let modifiedAt: String?

    var id: String { path }
}

struct DirectoryListResult: Decodable {
    let path: String
    let parent: String?
    let entries: [DirectoryEntry]
}

struct HomeResult: Decodable {
    let homePath: String
    let suggestedPaths: [SuggestedPath]?
}

struct SuggestedPath: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let exists: Bool?

    var id: String { path }
}

// MARK: - Memory Methods

struct MemorySearchParams: Encodable {
    let searchText: String?
    let type: String?
    let source: String?
    let limit: Int?
}

struct MemoryEntry: Decodable, Identifiable {
    let id: String
    let type: String
    let content: String
    let source: String
    let relevance: Double?
    let timestamp: String?
}

struct MemorySearchResult: Decodable {
    let entries: [MemoryEntry]
    let totalCount: Int
}

struct HandoffsParams: Encodable {
    let workingDirectory: String?
    let limit: Int?
}

struct Handoff: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let summary: String
    let createdAt: String
}

struct HandoffsResult: Decodable {
    let handoffs: [Handoff]
}

// MARK: - Event Sync Methods

/// Get event history for a session
struct EventsGetHistoryParams: Encodable {
    let sessionId: String
    let types: [String]?
    let limit: Int?
    let beforeEventId: String?

    init(sessionId: String, types: [String]? = nil, limit: Int? = nil, beforeEventId: String? = nil) {
        self.sessionId = sessionId
        self.types = types
        self.limit = limit
        self.beforeEventId = beforeEventId
    }
}

/// Raw event from server (matches core/events/types.ts)
struct RawEvent: Decodable {
    let id: String
    let parentId: String?
    let sessionId: String
    let workspaceId: String
    let type: String
    let timestamp: String
    let sequence: Int
    let payload: [String: AnyCodable]
}

struct EventsGetHistoryResult: Decodable {
    let events: [RawEvent]
    let hasMore: Bool
    let oldestEventId: String?
}

/// Get events since a cursor (for sync)
struct EventsGetSinceParams: Encodable {
    let sessionId: String?
    let workspaceId: String?
    let afterEventId: String?
    let afterTimestamp: String?
    let limit: Int?

    init(sessionId: String? = nil, workspaceId: String? = nil, afterEventId: String? = nil, afterTimestamp: String? = nil, limit: Int? = nil) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.afterEventId = afterEventId
        self.afterTimestamp = afterTimestamp
        self.limit = limit
    }
}

struct EventsGetSinceResult: Decodable {
    let events: [RawEvent]
    let nextCursor: String?
    let hasMore: Bool
}

/// Session info from server (for session.list with full event metadata)
struct ServerSessionInfo: Decodable {
    let sessionId: String
    let workspaceId: String?
    let headEventId: String?
    let rootEventId: String?
    let status: String?
    let title: String?
    let model: String
    let provider: String?
    let workingDirectory: String?
    let createdAt: String
    let lastActivityAt: String?
    let eventCount: Int?
    let messageCount: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let isActive: Bool
}

// MARK: - Worktree Methods

/// Worktree information for a session
struct WorktreeInfo: Decodable, Equatable {
    let isolated: Bool
    let branch: String
    let baseCommit: String
    let path: String
    let hasUncommittedChanges: Bool?
    let commitCount: Int?

    /// Short branch name (removes 'session/' prefix if present)
    var shortBranch: String {
        if branch.hasPrefix("session/") {
            return String(branch.dropFirst(8))
        }
        return branch
    }
}

/// Get worktree status for a session
struct WorktreeGetStatusParams: Encodable {
    let sessionId: String
}

struct WorktreeGetStatusResult: Decodable {
    let hasWorktree: Bool
    let worktree: WorktreeInfo?
}

/// Commit changes in a session's worktree
struct WorktreeCommitParams: Encodable {
    let sessionId: String
    let message: String
}

struct WorktreeCommitResult: Decodable {
    let success: Bool
    let commitHash: String?
    let filesChanged: [String]?
    let error: String?
}

/// Merge a session's worktree to a target branch
struct WorktreeMergeParams: Encodable {
    let sessionId: String
    let targetBranch: String
    let strategy: String?

    init(sessionId: String, targetBranch: String, strategy: String? = nil) {
        self.sessionId = sessionId
        self.targetBranch = targetBranch
        self.strategy = strategy
    }
}

struct WorktreeMergeResult: Decodable {
    let success: Bool
    let mergeCommit: String?
    let conflicts: [String]?
    let error: String?
}

/// List all worktrees
struct WorktreeListItem: Decodable, Identifiable, Hashable {
    let path: String
    let branch: String
    let sessionId: String?

    var id: String { path }
}

struct WorktreeListResult: Decodable {
    let worktrees: [WorktreeListItem]
}
