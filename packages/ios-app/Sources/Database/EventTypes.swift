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

    /// Human-readable summary of the event
    var summary: String {
        switch eventType {
        case .sessionStart:
            return "Session started"
        case .sessionEnd:
            return "Session ended"
        case .sessionFork:
            let name = (payload["name"]?.value as? String) ?? "unnamed"
            return "Forked: \(name)"
        case .messageUser:
            if let content = payload["content"]?.value as? String {
                return String(content.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "User message"
        case .messageAssistant:
            // Extract actual content from the response
            if let content = payload["content"]?.value as? String, !content.isEmpty {
                let preview = content.prefix(80).trimmingCharacters(in: .whitespacesAndNewlines)
                return preview + (content.count > 80 ? "..." : "")
            } else if let text = payload["text"]?.value as? String, !text.isEmpty {
                let preview = text.prefix(80).trimmingCharacters(in: .whitespacesAndNewlines)
                return preview + (text.count > 80 ? "..." : "")
            }
            return "Assistant response"
        case .toolCall:
            let name = (payload["name"]?.value as? String) ?? "unknown"
            return "Tool: \(name)"
        case .toolResult:
            let isError = (payload["isError"]?.value as? Bool) ?? false
            return "Result (\(isError ? "error" : "success"))"
        case .ledgerUpdate:
            return "Ledger updated"
        case .configModelSwitch:
            let model = (payload["model"]?.value as? String) ?? "unknown"
            return "Switched to \(model.shortModelName)"
        case .compactBoundary:
            return "Context compacted"
        case .unknown:
            return type
        default:
            return type
        }
    }

    /// Extended content for expanded view
    var expandedContent: String? {
        switch eventType {
        case .messageAssistant:
            if let content = payload["content"]?.value as? String {
                return content
            } else if let text = payload["text"]?.value as? String {
                return text
            }
            return nil
        case .toolCall:
            if let input = payload["input"]?.value {
                return "Input: \(input)"
            }
            return nil
        case .toolResult:
            if let content = payload["content"]?.value as? String {
                return content
            } else if let result = payload["result"]?.value as? String {
                return result
            }
            return nil
        default:
            return nil
        }
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
