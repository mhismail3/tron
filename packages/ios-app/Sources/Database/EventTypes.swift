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
            // Extract text content
            var content = ""
            if let text = payload.string("content"), !text.isEmpty {
                content = String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let text = payload.string("text"), !text.isEmpty {
                content = String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                content = "Assistant response"
            }

            // Add metadata indicators
            var indicators: [String] = []
            if let latency = payload.int("latency") {
                indicators.append(formatLatency(latency))
            }
            if payload.bool("hasThinking") == true {
                indicators.append("Thinking")
            }

            if !indicators.isEmpty {
                content += " • " + indicators.joined(separator: " • ")
            }
            return content

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
        switch toolName.lowercased() {
        case "read", "write", "edit":
            if let path = args["file_path"] as? String ?? args["path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case "bash":
            if let cmd = args["command"] as? String {
                return String(cmd.prefix(25))
            }
        case "search":
            if let pattern = args["pattern"] as? String {
                return "\"\(String(pattern.prefix(20)))\""
            }
        case "glob", "find":
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
        case .messageAssistant:
            var lines: [String] = []

            // Model info
            if let model = payload["model"]?.value as? String {
                lines.append("Model: \(model)")
            }

            // Turn info
            if let turn = payload["turn"]?.value as? Int {
                lines.append("Turn: \(turn)")
            }

            // Latency
            if let latency = payload["latency"]?.value as? Int {
                lines.append("Latency: \(formatLatency(latency))")
            }

            // Stop reason
            if let stopReason = payload["stopReason"]?.value as? String {
                lines.append("Stop reason: \(stopReason)")
            }

            // Extended thinking
            if payload["hasThinking"]?.value as? Bool == true {
                lines.append("Extended thinking: Yes")
            }

            // Token usage from tokenRecord
            if let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
               let source = tokenRecord["source"] as? [String: Any],
               let input = source["rawInputTokens"] as? Int,
               let output = source["rawOutputTokens"] as? Int {
                lines.append("Tokens: ↓\(TokenFormatter.format(input, style: .uppercase)) ↑\(TokenFormatter.format(output, style: .uppercase))")
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
    /// Whether session has ended (derived from ended_at IS NOT NULL)
    var endedAt: String?
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

    /// Whether session has ended
    var isEnded: Bool { endedAt != nil }

    // Dashboard display fields
    var lastUserPrompt: String?
    var lastAssistantResponse: String?
    var lastToolCount: Int?
    var isProcessing: Bool?

    /// Whether this session is a fork of another session
    var isFork: Bool?

    /// Server origin (host:port) this session was synced from
    var serverOrigin: String?

    var totalTokens: Int { inputTokens + outputTokens }

    /// Formatted token counts (e.g., "↓1.2k ↑3.4k")
    var formattedTokens: String {
        TokenFormatter.formatPair(input: inputTokens, output: outputTokens)
    }

    /// Formatted cache tokens - separate read/creation for visibility
    var formattedCacheTokens: String? {
        if cacheReadTokens == 0 && cacheCreationTokens == 0 { return nil }
        return "⚡\(cacheReadTokens.formattedTokenCount) read, \(cacheCreationTokens.formattedTokenCount) write"
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
        // Parse ISO8601 timestamp with fractional seconds support
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = isoFormatter.date(from: lastActivityAt)

        // Fallback: try without fractional seconds
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: lastActivityAt)
        }

        guard let parsedDate = date else {
            // Last resort: try to extract just the date/time portion
            return formatFallbackDate(lastActivityAt)
        }

        let now = Date()
        let interval = now.timeIntervalSince(parsedDate)

        // Within last 24 hours - use relative time like "7 minutes ago"
        if interval < 86400 && interval >= 0 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: parsedDate, relativeTo: now)
        }

        // Beyond 24 hours - use readable date format
        let dateFormatter = DateFormatter()
        if Calendar.current.isDate(parsedDate, equalTo: now, toGranularity: .year) {
            dateFormatter.dateFormat = "MMM d"  // e.g., "Jan 5"
        } else {
            dateFormatter.dateFormat = "MMM d, yyyy"  // e.g., "Jan 5, 2025"
        }
        return dateFormatter.string(from: parsedDate)
    }

    /// Fallback date formatting for non-standard ISO strings
    private func formatFallbackDate(_ dateString: String) -> String {
        // Try to extract date components from string like "2026-01-05T23:15:18.364Z"
        let components = dateString.components(separatedBy: "T")
        if components.count >= 2 {
            let datePart = components[0]
            let timePart = components[1].components(separatedBy: ".")[0]
                .components(separatedBy: "Z")[0]

            // Parse date manually
            let dateComponents = datePart.components(separatedBy: "-")
            let timeComponents = timePart.components(separatedBy: ":")

            if dateComponents.count == 3, timeComponents.count >= 2 {
                let month = Int(dateComponents[1]) ?? 1
                let day = Int(dateComponents[2]) ?? 1
                let hour = Int(timeComponents[0]) ?? 0
                let minute = Int(timeComponents[1]) ?? 0

                let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                let monthName = monthNames[max(0, min(11, month - 1))]

                // Format as "Jan 5, 3:15 PM"
                let hour12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
                let ampm = hour >= 12 ? "PM" : "AM"
                return "\(monthName) \(day), \(hour12):\(String(format: "%02d", minute)) \(ampm)"
            }
        }

        // If all else fails, return the original string
        return dateString
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
