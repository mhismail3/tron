import Foundation

/// Pure formatting logic for subagent event display.
/// Extracted from SubagentState to separate presentation from state management.
enum SubagentEventFormatter {

    /// Format a tool name with an appropriate emoji prefix.
    static func formatToolTitle(_ toolName: String?) -> String {
        guard let name = toolName else { return "Tool" }
        switch ToolKind(toolName: name) {
        case .bash: return "🖥 Bash"
        case .read: return "📄 Read"
        case .write: return "✏️ Write"
        case .edit: return "📝 Edit"
        case .search: return "🔍 Search"
        case .glob: return "📂 Find"
        default: return name
        }
    }

    /// Format a tool result for display, with tool-specific formatting.
    static func formatToolResult(toolName: String?, result: String, success: Bool) -> String {
        let cleaned = cleanResult(result)

        if !success {
            return String(cleaned.prefix(150))
        }

        let kind = toolName.map { ToolKind(toolName: $0) }
        switch kind {
        case .bash:
            return formatBashResult(cleaned)
        case .read:
            return formatReadResult(cleaned)
        case .search:
            return formatSearchResult(cleaned)
        case .write, .edit:
            return formatWriteResult(cleaned)
        default:
            return String(cleaned.prefix(150))
        }
    }

    /// Remove JSON wrappers and unescape common escape sequences.
    static func cleanResult(_ result: String) -> String {
        var cleaned = result

        if cleaned.hasPrefix("{\"") && cleaned.contains("\"content\":") {
            if let data = cleaned.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? String {
                cleaned = content
            }
        }

        cleaned = cleaned
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Format bash output: show first 2 lines + count if long.
    static func formatBashResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count <= 3 {
            return lines.joined(separator: "\n")
        }
        let preview = lines.prefix(2).joined(separator: "\n")
        return "\(preview)\n... +\(lines.count - 2) more lines"
    }

    /// Format read output: show line count if long.
    static func formatReadResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n")
        if lines.count <= 5 {
            return String(result.prefix(200))
        }
        return "\(lines.count) lines read"
    }

    /// Format search output: show match count.
    static func formatSearchResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.isEmpty {
            return "No matches"
        }
        if lines.count == 1 {
            return String(lines[0].prefix(100))
        }
        return "\(lines.count) matches found"
    }

    /// Format write/edit output: detect success.
    static func formatWriteResult(_ result: String) -> String {
        if result.lowercased().contains("success") || result.lowercased().contains("written") {
            return "✓ File saved"
        }
        return String(result.prefix(100))
    }

    /// Format accumulated streaming output: show last few lines.
    static func formatAccumulatedOutput(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = cleaned.components(separatedBy: "\n")

        if lines.count <= 4 {
            return String(cleaned.prefix(300))
        }

        let lastLines = lines.suffix(3).joined(separator: "\n")
        return "...\n\(lastLines)"
    }
}
