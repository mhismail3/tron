import Foundation

// MARK: - Session Methods

struct SessionCreateParams: Encodable {
    let workingDirectory: String
    let model: String?
    let contextFiles: [String]?

    init(
        workingDirectory: String,
        model: String? = nil,
        contextFiles: [String]? = nil
    ) {
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

    /// Formatted token counts including cache (e.g., "↓1.2k ↑3.4k ⚡20.3k ✏8.0k")
    var formattedTokens: String {
        let result = TokenFormatter.formatFullSession(
            input: inputTokens ?? 0,
            output: outputTokens ?? 0,
            cacheRead: cacheReadTokens,
            cacheWrite: cacheCreationTokens
        )
        // DEBUG: Log token values for session cards
        logger.debug("[SESSION-TOKENS] \(sessionId.prefix(12)): in=\(inputTokens ?? 0) out=\(outputTokens ?? 0) cacheRead=\(cacheReadTokens ?? 0) cacheWrite=\(cacheCreationTokens ?? 0) -> \(result)", category: .session)
        return result
    }

    /// Formatted cache tokens - separate read/creation for visibility
    var formattedCacheTokens: String? {
        let read = cacheReadTokens ?? 0
        let creation = cacheCreationTokens ?? 0
        if read == 0 && creation == 0 { return nil }
        return "⚡\(read.formattedTokenCount) read, ✏\(creation.formattedTokenCount) write"
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
