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
struct SessionEvent: Identifiable, Codable {
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
            let model = (payload["model"]?.value as? String) ?? "unknown"
            return "Session started • \(model.shortModelName)"

        case .sessionEnd:
            let reason = (payload["reason"]?.value as? String) ?? "completed"
            return "Session ended (\(reason))"

        case .sessionFork:
            return "Forked session"

        case .messageUser:
            if let content = payload["content"]?.value as? String {
                return String(content.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "User message"

        case .messageAssistant:
            // Extract text content
            var content = ""
            if let text = payload["content"]?.value as? String, !text.isEmpty {
                content = String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let text = payload["text"]?.value as? String, !text.isEmpty {
                content = String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                content = "Assistant response"
            }

            // Add metadata indicators
            var indicators: [String] = []
            if let latency = payload["latency"]?.value as? Int {
                indicators.append(formatLatency(latency))
            }
            if payload["hasThinking"]?.value as? Bool == true {
                indicators.append("Thinking")
            }

            if !indicators.isEmpty {
                content += " • " + indicators.joined(separator: " • ")
            }
            return content

        case .toolCall:
            let name = (payload["name"]?.value as? String) ?? "unknown"
            let args = payload["arguments"]?.value as? [String: Any] ?? [:]
            let keyArg = extractKeyArgument(toolName: name, from: args)
            if !keyArg.isEmpty {
                return "\(name): \(keyArg)"
            }
            return name

        case .toolResult:
            let isError = (payload["isError"]?.value as? Bool) ?? false
            let duration = payload["duration"]?.value as? Int
            let status = isError ? "error" : "success"
            if let duration = duration {
                return "\(duration)ms • \(status)"
            }
            return status

        case .streamTurnStart:
            let turn = (payload["turn"]?.value as? Int) ?? 0
            return "Turn \(turn) started"

        case .streamTurnEnd:
            let turn = (payload["turn"]?.value as? Int) ?? 0
            if let tokenUsage = payload["tokenUsage"]?.value as? [String: Any],
               let input = tokenUsage["inputTokens"] as? Int,
               let output = tokenUsage["outputTokens"] as? Int {
                return "Turn \(turn) • \(formatTokens(input + output)) tokens"
            }
            return "Turn \(turn) ended"

        case .errorAgent:
            let code = (payload["code"]?.value as? String) ?? "ERROR"
            let error = (payload["error"]?.value as? String) ?? "Unknown error"
            return "\(code): \(String(error.prefix(30)))"

        case .errorProvider:
            let provider = (payload["provider"]?.value as? String) ?? "provider"
            let retryable = (payload["retryable"]?.value as? Bool) ?? false
            if retryable, let delay = payload["retryAfter"]?.value as? Int {
                return "\(provider) • retry in \(delay)ms"
            }
            return "\(provider) error"

        case .errorTool:
            let toolName = (payload["toolName"]?.value as? String) ?? "tool"
            return "\(toolName) failed"

        case .ledgerUpdate:
            return "Ledger updated"

        case .configModelSwitch:
            let from = (payload["previousModel"]?.value as? String)?.shortModelName ?? "?"
            let to = (payload["newModel"]?.value as? String)?.shortModelName ??
                     (payload["model"]?.value as? String)?.shortModelName ?? "?"
            return "\(from) → \(to)"

        case .compactBoundary:
            return "Context compacted"

        case .unknown:
            return type

        default:
            return type
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
        case "grep":
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

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else {
            return String(format: "%.1fK", Double(tokens) / 1000.0)
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

            // Token usage
            if let tokenUsage = payload["tokenUsage"]?.value as? [String: Any] {
                if let input = tokenUsage["inputTokens"] as? Int,
                   let output = tokenUsage["outputTokens"] as? Int {
                    lines.append("Tokens: ↓\(formatTokens(input)) ↑\(formatTokens(output))")
                }
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

            if let tokenUsage = payload["tokenUsage"]?.value as? [String: Any] {
                if let input = tokenUsage["inputTokens"] as? Int {
                    lines.append("Input tokens: \(formatTokens(input))")
                }
                if let output = tokenUsage["outputTokens"] as? Int {
                    lines.append("Output tokens: \(formatTokens(output))")
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
    case streamTurnStart = "stream.turn_start"
    case streamTurnEnd = "stream.turn_end"

    case configModelSwitch = "config.model_switch"
    case configPromptUpdate = "config.prompt_update"

    case ledgerUpdate = "ledger.update"
    case ledgerGoal = "ledger.goal"
    case ledgerTask = "ledger.task"

    case compactBoundary = "compact.boundary"
    case compactSummary = "compact.summary"

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
    var status: SessionStatus
    var title: String?
    var model: String
    var provider: String
    var workingDirectory: String
    var createdAt: String
    var lastActivityAt: String
    var eventCount: Int
    var messageCount: Int
    var inputTokens: Int
    var outputTokens: Int

    // Dashboard display fields
    var lastUserPrompt: String?
    var lastAssistantResponse: String?
    var lastToolCount: Int?
    var isProcessing: Bool?

    var totalTokens: Int { inputTokens + outputTokens }

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

enum SessionStatus: String, Codable {
    case active
    case ended
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

/// Reconstructed session state at a point in time
struct ReconstructedSessionState {
    var messages: [ReconstructedMessage]
    var tokenUsage: TokenUsage
    var turnCount: Int
    var ledger: ReconstructedLedger?
}

struct ReconstructedMessage {
    let role: String
    let content: Any

    // MARK: - Enriched Metadata (Phase 1)
    // These fields come from server-side event store enhancements

    /// Model that generated this response (for assistant messages)
    var model: String?

    /// Response latency in milliseconds
    var latencyMs: Int?

    /// Turn number in the agent loop
    var turnNumber: Int?

    /// Whether extended thinking was used
    var hasThinking: Bool?

    /// Why the turn ended (end_turn, tool_use, max_tokens)
    var stopReason: String?

    /// Token usage for this message
    var tokenUsage: TokenUsage?

    init(
        role: String,
        content: Any,
        model: String? = nil,
        latencyMs: Int? = nil,
        turnNumber: Int? = nil,
        hasThinking: Bool? = nil,
        stopReason: String? = nil,
        tokenUsage: TokenUsage? = nil
    ) {
        self.role = role
        self.content = content
        self.model = model
        self.latencyMs = latencyMs
        self.turnNumber = turnNumber
        self.hasThinking = hasThinking
        self.stopReason = stopReason
        self.tokenUsage = tokenUsage
    }
}

struct ReconstructedLedger {
    var goal: String
    var now: String
    var next: [String]
    var done: [String]
    var constraints: [String]
    var workingFiles: [String]
    var decisions: [LedgerDecision]
}

struct LedgerDecision {
    let choice: String
    let reason: String
    let timestamp: String?
}
