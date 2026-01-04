import Foundation

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    var tokenUsage: TokenUsage?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: MessageContent,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        tokenUsage: TokenUsage? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.tokenUsage = tokenUsage
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
    case toolResult

    var displayName: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Tron"
        case .system: return "System"
        case .toolResult: return "Tool"
        }
    }
}

// MARK: - Message Content

enum MessageContent: Equatable {
    case text(String)
    case streaming(String)
    case thinking(visible: String, isExpanded: Bool)
    case toolUse(ToolUseData)
    case toolResult(ToolResultData)
    case error(String)
    case images([ImageContent])

    var textContent: String {
        switch self {
        case .text(let text), .streaming(let text):
            return text
        case .thinking(let visible, _):
            return visible
        case .toolUse(let tool):
            return "[\(tool.toolName)]"
        case .toolResult(let result):
            return result.content
        case .error(let message):
            return message
        case .images:
            return "[Images]"
        }
    }

    var isToolRelated: Bool {
        switch self {
        case .toolUse, .toolResult:
            return true
        default:
            return false
        }
    }
}

// MARK: - Tool Use Data

struct ToolUseData: Equatable {
    let toolName: String
    let toolCallId: String
    let arguments: String
    var status: ToolStatus
    var result: String?
    var durationMs: Int?

    var displayName: String {
        switch toolName.lowercased() {
        case "read": return "Reading file"
        case "write": return "Writing file"
        case "edit": return "Editing file"
        case "bash": return "Running command"
        case "glob": return "Searching files"
        case "grep": return "Searching content"
        case "task": return "Spawning agent"
        case "webfetch": return "Fetching URL"
        case "websearch": return "Searching web"
        default: return toolName
        }
    }

    var truncatedArguments: String {
        if arguments.count > 200 {
            return String(arguments.prefix(200)) + "..."
        }
        return arguments
    }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - Tool Status

enum ToolStatus: Equatable {
    case running
    case success
    case error

    var iconName: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Tool Result Data

struct ToolResultData: Equatable {
    let toolCallId: String
    let content: String
    let isError: Bool

    var truncatedContent: String {
        if content.count > 500 {
            return String(content.prefix(500)) + "..."
        }
        return content
    }
}

// MARK: - Image Content

struct ImageContent: Equatable, Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
    }
}

// MARK: - Message Extensions

extension ChatMessage {
    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text))
    }

    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    static func streaming(_ text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: .streaming(text), isStreaming: true)
    }

    static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: .text(text))
    }

    static func error(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .error(text))
    }
}
