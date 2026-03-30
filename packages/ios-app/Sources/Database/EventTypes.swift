import Foundation

// MARK: - Event Store Types

/// Unique identifier for events (branded type pattern)
struct EventId: Hashable, Codable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

/// Unique identifier for sessions (branded type pattern)
struct SessionId: Hashable, Codable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

/// Unique identifier for workspaces (branded type pattern)
struct WorkspaceId: Hashable, Codable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

// MARK: - Session Event

/// A single event in the event-sourced session tree
struct SessionEvent: Identifiable, Codable, EventTransformable {
    let id: String
    let parentId: String?
    let sessionId: String
    let workspaceId: String
    let type: String
    let timestamp: String
    let sequence: Int
    let payload: [String: AnyCodable]

    /// Event type enumeration
    var eventType: SessionEventType {
        SessionEventType(rawValue: type) ?? .unknown
    }

    /// Human-readable summary of the event (Phase 3 enhanced)
    var summary: String {
        switch eventType {
        case .sessionStart:
            let model = payload.string("model") ?? "unknown"
            return "Session started • \(model.shortModelName)"

        case .sessionEnd:
            let reason = payload.string("reason") ?? "completed"
            return "Session ended (\(reason))"

        case .sessionFork:
            return "Forked session"

        case .messageUser:
            if let content = payload.string("content") {
                return String(content.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "User message"

        case .messageAssistant:
            // Extract text from content blocks or plain string
            var text = ""
            if let contentArray = payload["content"]?.value as? [[String: Any]] {
                // Array of content blocks — extract text blocks
                let textParts = contentArray.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                text = textParts.joined(separator: " ")
            } else if let plain = payload.string("content"), !plain.isEmpty {
                text = plain
            }

            var summary = text.isEmpty
                ? "Assistant response"
                : String(text.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)

            // Add metadata indicators
            var indicators: [String] = []
            if let latency = payload.int("latency") {
                indicators.append(formatLatency(latency))
            }
            if payload.bool("hasThinking") == true {
                indicators.append("Thinking")
            }

            if !indicators.isEmpty {
                summary += " • " + indicators.joined(separator: " • ")
            }
            return summary

        case .toolCall:
            let name = payload.string("name") ?? "unknown"
            let args = payload.dict("arguments") ?? [:]
            let keyArg = extractKeyArgument(toolName: name, from: args)
            if !keyArg.isEmpty {
                return "\(name): \(keyArg)"
            }
            return name

        case .toolResult:
            let isError = payload.bool("isError") ?? false
            let duration = payload.int("duration")
            let status = isError ? "error" : "success"
            if let duration = duration {
                return "\(duration)ms • \(status)"
            }
            return status

        case .streamTurnStart:
            let turn = payload.int("turn") ?? 0
            return "Turn \(turn) started"

        case .streamTurnEnd:
            let turn = payload.int("turn") ?? 0
            if let tokenUsage = payload.dict("tokenUsage"),
               let input = tokenUsage["inputTokens"] as? Int,
               let output = tokenUsage["outputTokens"] as? Int {
                return "Turn \(turn) • \(TokenFormatter.format(input + output, style: .uppercase)) tokens"
            }
            return "Turn \(turn) ended"

        case .errorAgent:
            let code = payload.string("code") ?? "ERROR"
            let error = payload.string("error") ?? "Unknown error"
            return "\(code): \(String(error.prefix(30)))"

        case .errorProvider:
            let provider = payload.string("provider") ?? "provider"
            let retryable = payload.bool("retryable") ?? false
            if retryable, let delay = payload.int("retryAfter") {
                return "\(provider) • retry in \(delay)ms"
            }
            return "\(provider) error"

        case .errorTool:
            let toolName = payload.string("toolName") ?? "tool"
            return "\(toolName) failed"

        case .configModelSwitch:
            let from = payload.string("previousModel")?.shortModelName ?? "?"
            let to = payload.string("newModel")?.shortModelName ??
                     payload.string("model")?.shortModelName ?? "?"
            return "\(from) → \(to)"

        case .notificationInterrupted:
            return "Session interrupted"

        case .compactBoundary:
            return "Context compacted"

        case .compactSummary:
            return "Context summarized"

        case .rulesLoaded:
            let count = payload.int("count") ?? 0
            if count > 0 {
                return "Rules loaded (\(count))"
            }
            return "Rules loaded"

        case .rulesActivated:
            let count = payload.int("totalActivated") ?? 0
            if count > 0 {
                return "Rules activated (\(count))"
            }
            return "Rules activated"

        case .contextCleared:
            return "Context cleared"

        case .skillAdded:
            let name = payload.string("name") ?? payload.string("skillName") ?? ""
            if !name.isEmpty {
                return "Skill: \(name)"
            }
            return "Skill added"

        case .skillRemoved:
            let name = payload.string("name") ?? payload.string("skillName") ?? ""
            if !name.isEmpty {
                return "Skill removed: \(name)"
            }
            return "Skill removed"

        case .sessionBranch:
            return "Branch created"

        case .messageSystem:
            return "System message"

        case .messageDeleted:
            return "Message deleted"

        case .configPromptUpdate:
            return "Prompt updated"

        case .configReasoningLevel:
            let level = payload.string("level") ?? payload.string("reasoningLevel") ?? ""
            if !level.isEmpty {
                return "Reasoning: \(level)"
            }
            return "Reasoning level changed"

        case .metadataUpdate:
            return "Metadata updated"

        case .metadataTag:
            let tag = payload.string("tag") ?? ""
            if !tag.isEmpty {
                return "Tag: \(tag)"
            }
            return "Tag added"

        case .fileRead:
            if let path = payload.string("path") ?? payload.string("file_path") {
                return "Read: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "File read"

        case .fileWrite:
            if let path = payload.string("path") ?? payload.string("file_path") {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "File written"

        case .fileEdit:
            if let path = payload.string("path") ?? payload.string("file_path") {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "File edited"

        case .streamTextDelta, .streamThinkingDelta, .streamThinkingComplete:
            return "Streaming..."

        case .worktreeAcquired:
            let branch = payload.string("branch") ?? ""
            return branch.isEmpty ? "Worktree acquired" : "Worktree: \(branch)"

        case .worktreeCommit:
            let message = payload.string("message") ?? ""
            if !message.isEmpty {
                return "Commit: \(String(message.prefix(35)))"
            }
            return "Worktree commit"

        case .worktreeReleased:
            let deleted = payload.bool("deleted") ?? false
            return deleted ? "Worktree released (deleted)" : "Worktree released"

        case .worktreeMerged:
            return "Worktree merged"

        case .notificationProcessResult:
            let label = payload.string("label") ?? ""
            if !label.isEmpty {
                return "Process done: \(String(label.prefix(30)))"
            }
            return "Process result"

        case .processResultsConsumed:
            let count = payload.int("count") ?? 0
            return count > 0 ? "Results consumed (\(count))" : "Results consumed"

        case .unknown:
            // Format raw type into friendly name: "rules.loaded" -> "Rules loaded"
            let formatted = type
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return formatted
        }
    }

    /// Helper to extract key argument for tool display
    private func extractKeyArgument(toolName: String, from args: [String: Any]) -> String {
        switch ToolKind(toolName: toolName) {
        case .read, .write, .edit:
            if let path = args["file_path"] as? String ?? args["path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case .bash:
            if let cmd = args["command"] as? String {
                return String(cmd.prefix(25))
            }
        case .search:
            if let pattern = args["pattern"] as? String {
                return "\"\(String(pattern.prefix(20)))\""
            }
        case .glob:
            if let pattern = args["pattern"] as? String {
                return pattern
            }
        default:
            break
        }
        return ""
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Extended content for expanded view (Phase 3 enhanced)
    var expandedContent: String? {
        switch eventType {
        case .messageUser:
            guard let content = payload.string("content"), !content.isEmpty else { return nil }
            // Only show expanded if content is longer than the summary preview
            guard content.count > 50 else { return nil }
            return String(content.prefix(500))

        case .messageAssistant:
            var lines: [String] = []

            // Full text content from content blocks
            var fullText = ""
            if let contentArray = payload["content"]?.value as? [[String: Any]] {
                let textParts = contentArray.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                fullText = textParts.joined(separator: "\n\n")
            } else if let plain = payload.string("content") {
                fullText = plain
            }

            if !fullText.isEmpty {
                lines.append(String(fullText.prefix(500)))
            }

            // Metadata section
            var meta: [String] = []
            if let model = payload["model"]?.value as? String {
                meta.append("Model: \(model)")
            }
            if let turn = payload["turn"]?.value as? Int {
                meta.append("Turn: \(turn)")
            }
            if let latency = payload["latency"]?.value as? Int {
                meta.append("Latency: \(formatLatency(latency))")
            }
            if let stopReason = payload["stopReason"]?.value as? String {
                meta.append("Stop reason: \(stopReason)")
            }
            if payload["hasThinking"]?.value as? Bool == true {
                meta.append("Extended thinking: Yes")
            }
            if let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
               let source = tokenRecord["source"] as? [String: Any],
               let input = source["rawInputTokens"] as? Int,
               let output = source["rawOutputTokens"] as? Int {
                meta.append("Tokens: ↓\(TokenFormatter.format(input, style: .uppercase)) ↑\(TokenFormatter.format(output, style: .uppercase))")
            }

            if !meta.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: meta)
            }

            return lines.isEmpty ? nil : lines.joined(separator: "\n")

        case .toolCall:
            let name = (payload["name"]?.value as? String) ?? "unknown"
            let turn = (payload["turn"]?.value as? Int) ?? 0
            var lines = ["Tool: \(name)", "Turn: \(turn)"]

            // Format arguments if present and not too long
            if let args = payload["arguments"]?.value {
                let argsStr = formatJSON(args)
                if argsStr.count < 200 {
                    lines.append("Arguments:\n\(argsStr)")
                }
            }
            return lines.joined(separator: "\n")

        case .toolResult:
            var lines: [String] = []

            // Duration
            if let duration = payload["duration"]?.value as? Int {
                lines.append("Duration: \(duration)ms")
            }

            // Status
            let isError = (payload["isError"]?.value as? Bool) ?? false
            lines.append("Status: \(isError ? "Error" : "Success")")

            // Truncated flag
            if payload["truncated"]?.value as? Bool == true {
                lines.append("Content: Truncated")
            }

            // Content preview
            if let content = payload["content"]?.value as? String {
                let preview = String(content.prefix(200))
                lines.append("\n\(preview)")
            }
            return lines.joined(separator: "\n")

        case .errorAgent, .errorProvider, .errorTool:
            var lines: [String] = []

            // Error message
            if let error = payload["error"]?.value as? String {
                lines.append("Error: \(error)")
            }

            // Error code
            if let code = payload["code"]?.value as? String {
                lines.append("Code: \(code)")
            }

            // Recoverable
            if let recoverable = payload["recoverable"]?.value as? Bool {
                lines.append("Recoverable: \(recoverable ? "Yes" : "No")")
            }

            // Retryable
            if let retryable = payload["retryable"]?.value as? Bool {
                lines.append("Retryable: \(retryable ? "Yes" : "No")")
            }

            // Retry after
            if let retryAfter = payload["retryAfter"]?.value as? Int {
                lines.append("Retry after: \(retryAfter)ms")
            }

            return lines.joined(separator: "\n")

        case .streamTurnEnd:
            var lines: [String] = []

            if let turn = payload["turn"]?.value as? Int {
                lines.append("Turn: \(turn)")
            }

            // Token usage from tokenRecord
            if let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
               let source = tokenRecord["source"] as? [String: Any] {
                if let input = source["rawInputTokens"] as? Int {
                    lines.append("Input tokens: \(TokenFormatter.format(input, style: .uppercase))")
                }
                if let output = source["rawOutputTokens"] as? Int {
                    lines.append("Output tokens: \(TokenFormatter.format(output, style: .uppercase))")
                }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")

        default:
            return nil
        }
    }

    private func formatJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }

    // MARK: - Fork Safety

    /// Whether this event is a safe fork point for session branching.
    ///
    /// Only events where the message reconstruction state is consistent
    /// (no pending tool results, no unmatched tool_use blocks) are forkable.
    /// Mirrors the invariants in the Rust `build_messages` function in reconstruct.rs.
    var isForkable: Bool {
        switch eventType {
        case .messageUser:
            return true
        case .messageAssistant:
            return !contentHasToolUse
        default:
            return false
        }
    }

    /// Whether this assistant message's content contains tool_use blocks.
    /// Mirrors the Rust `content_has_tool_use` function in reconstruct.rs.
    private var contentHasToolUse: Bool {
        // Fast path: stopReason explicitly indicates tool use
        if payload.string("stopReason") == "tool_use" {
            return true
        }
        // Check content array for tool_use blocks (handles interrupted messages
        // where stopReason may be "interrupted" but content still has tool_use)
        guard let contentArray = payload["content"]?.value as? [[String: Any]] else {
            return false
        }
        return contentArray.contains { ($0["type"] as? String) == "tool_use" }
    }
}

/// Known session event types
enum SessionEventType: String, Codable {
    case sessionStart = "session.start"
    case sessionEnd = "session.end"
    case sessionFork = "session.fork"
    case sessionBranch = "session.branch"

    case messageUser = "message.user"
    case messageAssistant = "message.assistant"
    case messageSystem = "message.system"

    case toolCall = "tool.call"
    case toolResult = "tool.result"

    case streamTextDelta = "stream.text_delta"
    case streamThinkingDelta = "stream.thinking_delta"
    case streamThinkingComplete = "stream.thinking_complete"
    case streamTurnStart = "stream.turn_start"
    case streamTurnEnd = "stream.turn_end"

    case configModelSwitch = "config.model_switch"
    case configPromptUpdate = "config.prompt_update"
    case configReasoningLevel = "config.reasoning_level"

    // Message operations
    case messageDeleted = "message.deleted"

    // Notifications (in-chat pill notifications)
    case notificationInterrupted = "notification.interrupted"

    // Skills
    case skillAdded = "skill.added"
    case skillRemoved = "skill.removed"

    case compactBoundary = "compact.boundary"
    case compactSummary = "compact.summary"

    // Rules tracking
    case rulesLoaded = "rules.loaded"
    case rulesActivated = "rules.activated"

    // Context
    case contextCleared = "context.cleared"

    case metadataUpdate = "metadata.update"
    case metadataTag = "metadata.tag"

    case fileRead = "file.read"
    case fileWrite = "file.write"
    case fileEdit = "file.edit"

    case errorAgent = "error.agent"
    case errorTool = "error.tool"
    case errorProvider = "error.provider"

    // Worktree
    case worktreeAcquired = "worktree.acquired"
    case worktreeCommit = "worktree.commit"
    case worktreeReleased = "worktree.released"
    case worktreeMerged = "worktree.merged"

    // Process management
    case notificationProcessResult = "notification.process_result"
    case processResultsConsumed = "process.results_consumed"

    case unknown
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

// MARK: - Sync State

/// Tracks synchronization state with server
struct SyncState: Codable {
    let key: String
    var lastSyncedEventId: String?
    var lastSyncTimestamp: String?
    var pendingEventIds: [String]
}

// MARK: - Tree Node

/// Node for tree visualization
struct EventTreeNode: Identifiable {
    let id: String
    let parentId: String?
    let type: String
    let timestamp: String
    let summary: String
    let hasChildren: Bool
    let childCount: Int
    let depth: Int
    let isBranchPoint: Bool
    let isHead: Bool
}

// MARK: - Session State
// NOTE: Legacy types (ReconstructedSessionState, ReconstructedMessage)
// have been removed. Use ReconstructedState from Core/Events/Transformer/Reconstruction/.
