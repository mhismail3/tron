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
                return String(content.prefix(50))
            }
            return "User message"
        case .messageAssistant:
            return "Assistant response"
        case .toolCall:
            let name = (payload["name"]?.value as? String) ?? "unknown"
            return "Tool: \(name)"
        case .toolResult:
            let isError = (payload["isError"]?.value as? Bool) ?? false
            return "Tool result (\(isError ? "error" : "success"))"
        case .ledgerUpdate:
            return "Ledger updated"
        case .unknown:
            return type
        default:
            return type
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

    var totalTokens: Int { inputTokens + outputTokens }

    var displayTitle: String {
        if let title = title, !title.isEmpty {
            return title
        }
        return URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    var formattedDate: String {
        if let date = ISO8601DateFormatter().date(from: lastActivityAt) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return lastActivityAt
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
