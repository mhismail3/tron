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
    let inputTokens: Int?
    let outputTokens: Int?
    /// Current context size (input_tokens from last API call)
    let lastTurnInputTokens: Int?
    /// Total tokens read from prompt cache
    let cacheReadTokens: Int?
    /// Total tokens written to prompt cache
    let cacheCreationTokens: Int?
    let cost: Double?
    let isActive: Bool
    let workingDirectory: String?
    let parentSessionId: String?
    /// Last user prompt text (for preview display)
    let lastUserPrompt: String?
    /// Last assistant response text (for preview display)
    let lastAssistantResponse: String?

    var id: String { sessionId }

    /// Whether this session is a fork (has a parent session)
    var isFork: Bool { parentSessionId != nil }

    /// Display session ID prefix (first 20 characters)
    var displayName: String {
        String(sessionId.prefix(20))
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

    /// Formatted token counts (e.g., "↓1.2k ↑3.4k")
    var formattedTokens: String {
        TokenFormatter.formatPair(input: inputTokens ?? 0, output: outputTokens ?? 0)
    }

    /// Formatted cache tokens - separate read/creation for visibility
    var formattedCacheTokens: String? {
        let read = cacheReadTokens ?? 0
        let creation = cacheCreationTokens ?? 0
        if read == 0 && creation == 0 { return nil }
        return "⚡\(read.formattedTokenCount) read, \(creation.formattedTokenCount) write"
    }

    /// Formatted cost string (e.g., "$0.12")
    var formattedCost: String {
        let c = cost ?? 0
        if c < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", c)
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

/// Skill reference for wire format (sent with prompts)
struct SkillReferenceParam: Encodable {
    let name: String
    let source: String  // "global" or "project"

    init(from skill: Skill) {
        self.name = skill.name
        self.source = skill.source.rawValue
    }
}

struct AgentPromptParams: Encodable {
    let sessionId: String
    let prompt: String
    let images: [ImageAttachment]?
    let attachments: [FileAttachment]?
    let reasoningLevel: String?
    let skills: [SkillReferenceParam]?

    init(
        sessionId: String,
        prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.images = images
        self.attachments = attachments
        self.reasoningLevel = reasoningLevel
        self.skills = skills?.map { SkillReferenceParam(from: $0) }
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

/// Unified file attachment for images, PDFs, and documents
struct FileAttachment: Encodable {
    let data: String  // base64 encoded
    let mimeType: String
    let fileName: String?

    init(data: Data, mimeType: String, fileName: String? = nil) {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// Create from an Attachment model
    init(attachment: Attachment) {
        self.data = attachment.data.base64EncodedString()
        self.mimeType = attachment.mimeType
        self.fileName = attachment.fileName
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

// MARK: - Transcription Methods

struct TranscribeAudioParams: Encodable {
    let sessionId: String?
    let audioBase64: String
    let mimeType: String?
    let fileName: String?
    let transcriptionModelId: String?
    let cleanupMode: String?
    let language: String?
    let prompt: String?
    let task: String?
}

struct TranscribeAudioResult: Decodable {
    let text: String
    let rawText: String
    let language: String
    let durationSeconds: Double
    let processingTimeMs: Int
    let model: String
    let device: String
    let computeType: String
    let cleanupMode: String
}

struct TranscriptionModelInfo: Decodable, Identifiable {
    let id: String
    let label: String
    let description: String?
}

struct TranscribeListModelsResult: Decodable {
    let models: [TranscriptionModelInfo]
    let defaultModelId: String?
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

    var formattedInput: String { inputTokens.formattedTokenCount }
    var formattedOutput: String { outputTokens.formattedTokenCount }
    var formattedTotal: String { totalTokens.formattedTokenCount }
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

// MARK: - Session Delete/Fork

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
    let worktree: ForkWorktreeInfo?  // Worktree info including path
}

/// Simplified worktree info for fork results
struct ForkWorktreeInfo: Decodable {
    let isolated: Bool
    let branch: String?  // Can be null for non-isolated sessions
    let baseCommit: String?  // Can be null for non-isolated sessions
    let path: String
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
    /// For models with reasoning capability (e.g., OpenAI Codex)
    let supportsReasoning: Bool?
    /// Available reasoning effort levels (low, medium, high, xhigh)
    let reasoningLevels: [String]?
    /// Default reasoning level
    let defaultReasoningLevel: String?

    /// Properly formatted display name (e.g., "Claude Opus 4.5", "Claude Sonnet 4")
    var displayName: String {
        // For OpenAI models, use the name directly
        if provider == "openai-codex" || provider == "openai" {
            return name
        }
        return id.fullModelName
    }

    /// Short tier name: "Opus", "Sonnet", "Haiku"
    var shortName: String {
        // For OpenAI models, use the name directly
        if provider == "openai-codex" || provider == "openai" {
            return name
        }
        return ModelNameFormatter.format(id, style: .tierOnly, fallback: name)
    }

    /// Formats model name properly: "Claude Opus 4.5", "GPT-5.2 Codex", etc.
    /// Uses full format for Claude models, short format for Codex (avoids redundant "OpenAI" prefix)
    var formattedModelName: String {
        let lowerId = id.lowercased()
        if lowerId.contains("codex") {
            // Codex: "GPT-5.2 Codex" (short format - no "OpenAI" prefix)
            return id.shortModelName
        }
        // Claude: "Claude Opus 4.5" (full format with "Claude" prefix)
        return id.fullModelName
    }

    /// Whether this is a latest generation model (Claude 4.5+ or GPT-5.x Codex)
    var is45Model: Bool {
        let lowerId = id.lowercased()
        // Claude 4.5 family
        if lowerId.contains("4-5") || lowerId.contains("4.5") {
            return true
        }
        // GPT-5.x Codex models are also "latest"
        if lowerId.contains("codex") && (lowerId.contains("5.") || lowerId.contains("-5-")) {
            return true
        }
        return false
    }

    /// Whether this is an Anthropic model
    var isAnthropic: Bool {
        provider == "anthropic"
    }

    /// Whether this is an OpenAI Codex model
    var isCodex: Bool {
        provider == "openai-codex"
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

// MARK: - Create Directory

struct FilesystemCreateDirParams: Encodable {
    let path: String
    let recursive: Bool?

    init(path: String, recursive: Bool? = nil) {
        self.path = path
        self.recursive = recursive
    }
}

struct FilesystemCreateDirResult: Decodable {
    let created: Bool
    let path: String
}

// MARK: - Git Clone

struct GitCloneParams: Encodable {
    let url: String
    let targetPath: String
}

struct GitCloneResult: Decodable {
    let success: Bool
    let path: String
    let repoName: String
    let error: String?
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

// MARK: - Tree Methods

struct TreeGetAncestorsParams: Encodable {
    let eventId: String
}

struct TreeGetAncestorsResult: Decodable {
    let events: [RawEvent]
}

// MARK: - Voice Notes Methods

struct VoiceNotesSaveParams: Encodable {
    let audioBase64: String
    let mimeType: String?
    let fileName: String?
    let transcriptionModelId: String?
}

struct VoiceNotesSaveResult: Decodable {
    let success: Bool
    let filename: String
    let filepath: String
    let transcription: VoiceNoteTranscription
}

struct VoiceNoteTranscription: Decodable {
    let text: String
    let language: String
    let durationSeconds: Double
}

struct VoiceNotesListParams: Encodable {
    let limit: Int?
    let offset: Int?

    init(limit: Int? = nil, offset: Int? = nil) {
        self.limit = limit
        self.offset = offset
    }
}

struct VoiceNoteMetadata: Decodable, Identifiable {
    let filename: String
    let filepath: String
    let createdAt: String
    let durationSeconds: Double?
    let language: String?
    let preview: String
    let transcript: String

    var id: String { filename }

    /// Formatted date for display
    var formattedDate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        // Fallback: try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: createdAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return createdAt
    }

    /// Formatted duration (e.g., "2:34")
    var formattedDuration: String {
        guard let duration = durationSeconds else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct VoiceNotesListResult: Decodable {
    let notes: [VoiceNoteMetadata]
    let totalCount: Int
    let hasMore: Bool
}

struct VoiceNotesDeleteParams: Encodable {
    let filename: String
}

struct VoiceNotesDeleteResult: Decodable {
    let success: Bool
    let filename: String
}

// MARK: - Message Methods

struct MessageDeleteParams: Encodable {
    let sessionId: String
    let targetEventId: String
    let reason: String?

    init(sessionId: String, targetEventId: String, reason: String? = "user_request") {
        self.sessionId = sessionId
        self.targetEventId = targetEventId
        self.reason = reason
    }
}

struct MessageDeleteResult: Decodable {
    let success: Bool
    let deletionEventId: String
    let targetType: String
}

// MARK: - Tool Result Methods

/// Send tool result for interactive tools like AskUserQuestion
struct ToolResultParams: Encodable {
    let sessionId: String
    let toolCallId: String
    let result: AskUserQuestionResult
}

struct ToolResultResponse: Decodable {
    let success: Bool
}

// MARK: - Browser Methods

/// Start browser stream for a session
struct BrowserStartStreamParams: Encodable {
    let sessionId: String
    let quality: Int?
    let maxWidth: Int?
    let maxHeight: Int?
    let format: String?
    let everyNthFrame: Int?

    init(
        sessionId: String,
        quality: Int? = 60,
        maxWidth: Int? = 1280,
        maxHeight: Int? = 800,
        format: String? = "jpeg",
        everyNthFrame: Int? = 1
    ) {
        self.sessionId = sessionId
        self.quality = quality
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.format = format
        self.everyNthFrame = everyNthFrame
    }
}

struct BrowserStartStreamResult: Decodable {
    let success: Bool
    let error: String?
}

/// Stop browser stream for a session
struct BrowserStopStreamParams: Encodable {
    let sessionId: String
}

struct BrowserStopStreamResult: Decodable {
    let success: Bool
    let error: String?
}

/// Get browser status for a session
struct BrowserGetStatusParams: Encodable {
    let sessionId: String
}

struct BrowserGetStatusResult: Decodable {
    var hasBrowser: Bool
    var isStreaming: Bool
    var currentUrl: String?

    init(hasBrowser: Bool, isStreaming: Bool, currentUrl: String?) {
        self.hasBrowser = hasBrowser
        self.isStreaming = isStreaming
        self.currentUrl = currentUrl
    }
}

/// Browser frame event data (received via WebSocket events)
/// Server sends: { type: "browser.frame", sessionId, timestamp, data: { sessionId, data, frameId, timestamp, metadata } }
struct BrowserFrameEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: BrowserFrameData

    struct BrowserFrameData: Decodable {
        let sessionId: String
        /// Base64-encoded frame data (JPEG or PNG)
        let data: String
        /// Frame sequence number
        let frameId: Int
        /// Timestamp when frame was captured (milliseconds)
        let timestamp: Double
        /// Optional frame metadata
        let metadata: BrowserFrameMetadata?
    }

    /// Convenience accessors for nested data
    var frameData: String { data.data }
    var frameId: Int { data.frameId }
    var frameTimestamp: Double { data.timestamp }
    var frameSessionId: String { data.sessionId }
    var metadata: BrowserFrameMetadata? { data.metadata }
}

struct BrowserFrameMetadata: Decodable {
    let offsetTop: Double?
    let pageScaleFactor: Double?
    let deviceWidth: Double?
    let deviceHeight: Double?
    let scrollOffsetX: Double?
    let scrollOffsetY: Double?
}

// MARK: - Skill Methods

struct SkillListParams: Encodable {
    let sessionId: String?
    let source: String?
    let autoInjectOnly: Bool?
    let includeContent: Bool?

    init(sessionId: String? = nil, source: String? = nil, autoInjectOnly: Bool? = nil, includeContent: Bool? = nil) {
        self.sessionId = sessionId
        self.source = source
        self.autoInjectOnly = autoInjectOnly
        self.includeContent = includeContent
    }
}

struct SkillGetParams: Encodable {
    let sessionId: String?
    let name: String

    init(sessionId: String? = nil, name: String) {
        self.sessionId = sessionId
        self.name = name
    }
}

struct SkillRefreshParams: Encodable {
    let sessionId: String?

    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

struct SkillRemoveParams: Encodable {
    let sessionId: String
    let skillName: String
}

// MARK: - Canvas Methods

struct CanvasGetParams: Encodable {
    let canvasId: String
}

struct CanvasArtifactData: Decodable {
    let canvasId: String
    let sessionId: String
    let title: String?
    let ui: [String: AnyCodable]
    let state: [String: AnyCodable]?
    let savedAt: String
}

struct CanvasGetResult: Decodable {
    let found: Bool
    let canvas: CanvasArtifactData?
}

// MARK: - Todo Methods

/// Todo item returned from server
struct RpcTodoItem: Decodable, Identifiable, Hashable {
    let id: String
    let content: String
    let activeForm: String
    let status: TodoStatus
    let source: TodoSource
    let createdAt: String
    let completedAt: String?
    let metadata: [String: AnyCodable]?

    /// Status of a todo item
    enum TodoStatus: String, Decodable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed

        var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
            }
        }

        var icon: String {
            switch self {
            case .pending: return "circle"
            case .inProgress: return "circle.fill"
            case .completed: return "checkmark.circle.fill"
            }
        }
    }

    /// Source of a todo item
    enum TodoSource: String, Decodable {
        case agent
        case user
        case skill

        var displayName: String {
            switch self {
            case .agent: return "Agent"
            case .user: return "User"
            case .skill: return "Skill"
            }
        }
    }

    /// Format the createdAt timestamp for display (short format like "1m", "5h")
    var formattedCreatedAt: String {
        formatShortRelativeTime(createdAt)
    }

    /// Format the completedAt timestamp for display
    var formattedCompletedAt: String? {
        guard let completedAt else { return nil }
        return formatShortRelativeTime(completedAt)
    }

    /// Format as short relative time (e.g., "1m", "5h", "2d")
    /// Uses static calculation to avoid constant re-renders
    private func formatShortRelativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: isoString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: isoString)
        }
        guard let date else { return "" }

        let now = Date()
        let seconds = Int(now.timeIntervalSince(date))

        if seconds < 60 {
            return "now"
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return "\(minutes)m"
        } else if seconds < 86400 {
            let hours = seconds / 3600
            return "\(hours)h"
        } else {
            let days = seconds / 86400
            return "\(days)d"
        }
    }

    // Hashable conformance (ignore metadata for equality)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RpcTodoItem, rhs: RpcTodoItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.content == rhs.content &&
        lhs.activeForm == rhs.activeForm &&
        lhs.status == rhs.status &&
        lhs.source == rhs.source
    }
}

/// Backlogged task from a previous session
struct RpcBackloggedTask: Decodable, Identifiable, Hashable {
    let id: String
    let content: String
    let activeForm: String
    let status: RpcTodoItem.TodoStatus
    let source: RpcTodoItem.TodoSource
    let createdAt: String
    let completedAt: String?
    let metadata: [String: AnyCodable]?
    let backloggedAt: String
    let backlogReason: BacklogReason
    let sourceSessionId: String
    let workspaceId: String
    let restoredToSessionId: String?
    let restoredAt: String?

    enum BacklogReason: String, Decodable {
        case sessionClear = "session_clear"
        case contextCompact = "context_compact"
        case sessionEnd = "session_end"

        var displayName: String {
            switch self {
            case .sessionClear: return "Session Cleared"
            case .contextCompact: return "Context Compacted"
            case .sessionEnd: return "Session Ended"
            }
        }
    }

    /// Whether this task has been restored to another session
    var isRestored: Bool { restoredToSessionId != nil }

    /// Format the backloggedAt timestamp for display (short format)
    var formattedBackloggedAt: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: backloggedAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: backloggedAt)
        }
        guard let date else { return "" }

        let now = Date()
        let seconds = Int(now.timeIntervalSince(date))

        if seconds < 60 {
            return "now"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else if seconds < 86400 {
            return "\(seconds / 3600)h"
        } else {
            return "\(seconds / 86400)d"
        }
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RpcBackloggedTask, rhs: RpcBackloggedTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Parameters for todo.list
struct TodoListParams: Encodable {
    let sessionId: String
}

/// Result of todo.list
struct TodoListResult: Decodable {
    let todos: [RpcTodoItem]
    let summary: String
}

/// Parameters for todo.getBacklog
struct TodoGetBacklogParams: Encodable {
    let workspaceId: String
    let includeRestored: Bool?
    let limit: Int?

    init(workspaceId: String, includeRestored: Bool? = nil, limit: Int? = nil) {
        self.workspaceId = workspaceId
        self.includeRestored = includeRestored
        self.limit = limit
    }
}

/// Result of todo.getBacklog
struct TodoGetBacklogResult: Decodable {
    let tasks: [RpcBackloggedTask]
    let totalCount: Int
}

/// Parameters for todo.restore
struct TodoRestoreParams: Encodable {
    let sessionId: String
    let taskIds: [String]
}

/// Result of todo.restore
struct TodoRestoreResult: Decodable {
    let restoredTodos: [RpcTodoItem]
    let restoredCount: Int
}

/// Parameters for todo.getBacklogCount
struct TodoGetBacklogCountParams: Encodable {
    let workspaceId: String
}

/// Result of todo.getBacklogCount
struct TodoGetBacklogCountResult: Decodable {
    let count: Int
}
