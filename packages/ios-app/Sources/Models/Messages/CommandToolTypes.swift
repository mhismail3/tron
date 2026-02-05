import Foundation
import SwiftUI

// MARK: - Command Tool Status

/// Status for command tool execution
enum CommandToolStatus: Equatable {
    case running
    case success
    case error
}

// MARK: - Result Truncation

/// Constants for result truncation to prevent performance issues
enum ResultTruncation {
    /// Maximum number of lines to display in result viewers
    static let maxLines = 35

    /// Maximum number of characters to keep in result
    static let maxCharacters = 2_800

    /// Message appended when content is truncated
    static let truncationMessage = "\n\n... [Output truncated for performance]"

    /// Truncate content to fit within limits
    /// Returns (truncatedContent, wasTruncated)
    static func truncate(_ content: String) -> (String, Bool) {
        guard !content.isEmpty else { return (content, false) }

        // First check character limit (fast check)
        if content.count > maxCharacters {
            let truncated = String(content.prefix(maxCharacters)) + truncationMessage
            return (truncated, true)
        }

        // Then check line limit
        let lines = content.components(separatedBy: "\n")
        if lines.count > maxLines {
            let truncated = lines.prefix(maxLines).joined(separator: "\n") + truncationMessage
            return (truncated, true)
        }

        return (content, false)
    }
}

// MARK: - Command Tool Chip Data

/// Unified data for all command tool chips
/// Used to display command tools (Read, Write, Edit, Bash, etc.) as tappable chips
struct CommandToolChipData: Equatable, Identifiable {
    /// Tool call ID (used as unique identifier)
    let id: String
    /// Original tool name as received
    let toolName: String
    /// Normalized (lowercased) tool name for routing
    let normalizedName: String

    // Display properties
    /// SF Symbol name for the tool icon
    let icon: String
    /// Icon color
    let iconColor: Color
    /// Human-readable display name
    let displayName: String
    /// Truncated summary (path, command, pattern, etc.)
    let summary: String

    // Status properties
    /// Current execution status
    var status: CommandToolStatus
    /// Duration in milliseconds (nil while running)
    var durationMs: Int?

    // Full data for sheet
    /// Raw JSON arguments string
    let arguments: String
    /// Tool result (nil while running, truncated if too large)
    var result: String?
    /// Whether the result was truncated for performance
    var isResultTruncated: Bool

    /// Formatted duration for display
    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - Command Tool Registry

/// Registry for tool configurations and routing
enum CommandToolRegistry {

    /// All command tools that should be rendered as chips
    static let allCommandTools: Set<String> = [
        "read", "write", "edit",
        "bash",
        "search", "glob", "find",
        "browsetheweb", "openurl",
        "webfetch", "websearch",
        "task",
        "introspect"
    ]

    /// Special tools that have their own dedicated UI (not command tool chips)
    private static let specialTools: Set<String> = [
        "askuserquestion",
        "spawnsubagent", "queryagent", "waitforagents",
        "renderappui",
        "todowrite",
        "notifyapp",
        "adapt"
    ]

    /// Check if a tool should be rendered as a command tool chip
    static func isCommandTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return allCommandTools.contains(normalized)
    }

    /// Get display configuration for a tool
    /// Returns (icon: SF Symbol name, color: icon color, displayName: human-readable name)
    static func config(for toolName: String) -> (icon: String, color: Color, displayName: String) {
        switch toolName.lowercased() {
        case "read":
            return ("doc.text", .tronSlate, "Read")
        case "write":
            return ("doc.badge.plus", .tronPink, "Write")
        case "edit":
            return ("pencil.line", .orange, "Edit")
        case "bash":
            return ("terminal", .tronEmerald, "Bash")
        case "search":
            return ("magnifyingglass", .purple, "Search")
        case "glob", "find":
            return ("doc.text.magnifyingglass", .cyan, toolName.lowercased() == "glob" ? "Glob" : "Find")
        case "browsetheweb":
            return ("globe", .blue, "Browse Web")
        case "openurl":
            return ("safari", .blue, "Open URL")
        case "webfetch":
            return ("arrow.down.doc", .tronInfo, "Fetch")
        case "websearch":
            return ("magnifyingglass.circle", .tronInfo, "Search")
        case "task":
            return ("arrow.triangle.branch", .tronAmber, "Task")
        case "introspect":
            return ("cylinder.split.1x2", .tronInfo, "Introspect")
        default:
            return ("gearshape", .tronTextMuted, toolName.capitalized)
        }
    }
}

// MARK: - Factory Initializer

extension CommandToolChipData {

    /// Create CommandToolChipData from a ToolUseData
    /// Always succeeds - uses default config for unknown tools (gear icon)
    init(from tool: ToolUseData) {
        let normalized = tool.toolName.lowercased()
        let config = CommandToolRegistry.config(for: normalized)

        // Truncate result if too large to prevent performance issues
        let (truncatedResult, wasTruncated) = tool.result.map { ResultTruncation.truncate($0) } ?? (nil, false)

        self.id = tool.toolCallId
        self.toolName = tool.toolName
        self.normalizedName = normalized
        self.icon = config.icon
        self.iconColor = config.color
        self.displayName = config.displayName
        self.summary = Self.extractSummary(from: tool.arguments, toolName: normalized)
        self.status = Self.mapStatus(tool.status)
        self.durationMs = tool.durationMs
        self.arguments = tool.arguments
        self.result = truncatedResult
        self.isResultTruncated = wasTruncated
    }

    /// Map ToolStatus to CommandToolStatus
    private static func mapStatus(_ status: ToolStatus) -> CommandToolStatus {
        switch status {
        case .running: return .running
        case .success: return .success
        case .error: return .error
        }
    }

    /// Extract a summary string from tool arguments based on tool type
    private static func extractSummary(from args: String, toolName: String) -> String {
        switch toolName {
        case "read", "write", "edit":
            return shortenPath(extractFilePath(from: args))
        case "bash":
            return truncateCommand(extractCommand(from: args))
        case "search":
            let pattern = extractPattern(from: args)
            let path = extractPath(from: args)
            if !path.isEmpty && path != "." {
                return "\"\(pattern)\" in \(shortenPath(path))"
            }
            return "\"\(pattern)\""
        case "find", "glob":
            return extractPattern(from: args)
        case "browsetheweb":
            return extractBrowserAction(from: args)
        case "openurl":
            return extractOpenBrowserUrl(from: args)
        case "webfetch":
            return extractWebFetchSummary(from: args)
        case "websearch":
            return extractWebSearchSummary(from: args)
        case "task":
            return extractTaskDescription(from: args)
        default:
            return ""
        }
    }

    // MARK: - Argument Parsing Helpers

    /// Unescape JSON string escapes for display
    private static func unescapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\/", with: "/")
           .replacingOccurrences(of: "\\\"", with: "\"")
           .replacingOccurrences(of: "\\n", with: " ")
           .replacingOccurrences(of: "\\t", with: " ")
           .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func extractFilePath(from args: String) -> String {
        if let match = args.firstMatch(of: /"file_path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractPath(from args: String) -> String {
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return "."
    }

    private static func extractCommand(from args: String) -> String {
        if let match = args.firstMatch(of: /"command"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractPattern(from args: String) -> String {
        if let match = args.firstMatch(of: /"pattern"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractBrowserAction(from args: String) -> String {
        if let match = args.firstMatch(of: /"action"\s*:\s*"([^"]+)"/) {
            let action = String(match.1)
            if action == "navigate", let urlMatch = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
                let url = unescapeJSON(String(urlMatch.1))
                return "\(action): \(url)"
            }
            if ["click", "fill", "type", "select"].contains(action),
               let selectorMatch = args.firstMatch(of: /"selector"\s*:\s*"([^"]+)"/) {
                let selector = unescapeJSON(String(selectorMatch.1))
                return "\(action): \(selector)"
            }
            return action
        }
        return ""
    }

    private static func extractAstGrepPattern(from args: String) -> String {
        if let match = args.firstMatch(of: /"pattern"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        if let match = args.firstMatch(of: /"rule"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractOpenBrowserUrl(from args: String) -> String {
        if let match = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            let url = unescapeJSON(String(match.1))
            if url.count > 50 {
                return String(url.prefix(50)) + "..."
            }
            return url
        }
        return ""
    }

    private static func extractUrl(from args: String) -> String {
        if let match = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            let url = unescapeJSON(String(match.1))
            if url.count > 40 {
                return String(url.prefix(40)) + "..."
            }
            return url
        }
        return ""
    }

    private static func extractQuery(from args: String) -> String {
        if let match = args.firstMatch(of: /"query"\s*:\s*"([^"]+)"/) {
            let query = unescapeJSON(String(match.1))
            if query.count > 40 {
                return String(query.prefix(40)) + "..."
            }
            return query
        }
        return ""
    }

    // MARK: - WebFetch Summary

    private static func extractWebFetchSummary(from args: String) -> String {
        let url = extractWebFetchUrl(from: args)
        let prompt = extractWebFetchPrompt(from: args)

        if !url.isEmpty {
            // Show domain + truncated prompt
            let domain = extractDomain(from: url)
            if !prompt.isEmpty {
                let shortPrompt = prompt.count > 30 ? String(prompt.prefix(27)) + "..." : prompt
                return "\(domain): \(shortPrompt)"
            }
            return domain
        }
        // Fallback to prompt only if no URL
        return prompt.isEmpty ? "" : (prompt.count > 40 ? String(prompt.prefix(37)) + "..." : prompt)
    }

    private static func extractWebFetchUrl(from args: String) -> String {
        if let match = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractWebFetchPrompt(from args: String) -> String {
        if let match = args.firstMatch(of: /"prompt"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractDomain(from url: String) -> String {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else {
            // Fallback: try to extract domain manually
            if url.contains("://") {
                let afterProtocol = url.components(separatedBy: "://").last ?? url
                let domain = afterProtocol.components(separatedBy: "/").first ?? afterProtocol
                return domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
            }
            return String(url.prefix(30))
        }
        // Remove www. prefix for cleaner display
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - WebSearch Summary

    private static func extractWebSearchSummary(from args: String) -> String {
        let query = extractWebSearchQuery(from: args)
        guard !query.isEmpty else { return "" }

        // Show query in quotes (truncated if long)
        let truncated = query.count > 40 ? String(query.prefix(37)) + "..." : query
        return "\"\(truncated)\""
    }

    private static func extractWebSearchQuery(from args: String) -> String {
        if let match = args.firstMatch(of: /"query"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private static func extractTaskDescription(from args: String) -> String {
        if let match = args.firstMatch(of: /"description"\s*:\s*"([^"]+)"/) {
            let desc = unescapeJSON(String(match.1))
            if desc.count > 40 {
                return String(desc.prefix(40)) + "..."
            }
            return desc
        }
        if let match = args.firstMatch(of: /"prompt"\s*:\s*"([^"]+)"/) {
            let prompt = unescapeJSON(String(match.1))
            if prompt.count > 40 {
                return String(prompt.prefix(40)) + "..."
            }
            return prompt
        }
        return ""
    }

    private static func shortenPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func truncateCommand(_ cmd: String) -> String {
        guard cmd.count > 40 else { return cmd }
        return String(cmd.prefix(40)) + "..."
    }
}
