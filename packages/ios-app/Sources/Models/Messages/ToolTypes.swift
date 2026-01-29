import Foundation

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
        case "search": return "Searching content"
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
    let toolName: String?
    let arguments: String?
    let durationMs: Int?

    init(toolCallId: String, content: String, isError: Bool, toolName: String? = nil, arguments: String? = nil, durationMs: Int? = nil) {
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.toolName = toolName
        self.arguments = arguments
        self.durationMs = durationMs
    }

    var truncatedContent: String {
        if content.count > 500 {
            return String(content.prefix(500)) + "..."
        }
        return content
    }
}
