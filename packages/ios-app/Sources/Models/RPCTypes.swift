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

struct AgentStateResult: Decodable {
    let isRunning: Bool
    let currentTurn: Int
    let messageCount: Int
    let tokenUsage: TokenUsage?
    let model: String
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
    let fromMessageIndex: Int?
}

struct SessionForkResult: Decodable {
    let newSessionId: String
    let forkedFrom: String
    let messageCount: Int
}

struct SessionRewindParams: Encodable {
    let sessionId: String
    let toMessageIndex: Int
}

struct SessionRewindResult: Decodable {
    let sessionId: String
    let newMessageCount: Int
    let removedCount: Int
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

    var displayName: String {
        if let tier = tier {
            return "\(name) (\(tier))"
        }
        return name
    }

    var shortName: String {
        if id.contains("opus") { return "Opus" }
        if id.contains("sonnet") { return "Sonnet" }
        if id.contains("haiku") { return "Haiku" }
        return name
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
