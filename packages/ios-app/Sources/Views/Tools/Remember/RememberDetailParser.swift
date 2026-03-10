import Foundation

// MARK: - Model Types

struct RememberMemoryEntry {
    let index: Int
    let content: String
    let relevance: Int?
}

struct RememberSessionEntry {
    let sessionId: String
    let title: String
    let date: String
}

struct RememberStatEntry {
    let key: String
    let label: String
    let value: String
    let icon: String
}

// MARK: - Remember Detail Parser

enum RememberDetailParser {

    enum ActionCategory {
        case memorySearch   // recall, search, memory
        case sessionList    // sessions
        case sessionDetail  // session
        case eventQuery     // events, messages, tools, logs
        case dbStats        // stats
        case dbSchema       // schema
        case blobRead       // read_blob
    }

    static func actionCategory(from action: String) -> ActionCategory {
        switch action {
        case "recall", "search", "memory": return .memorySearch
        case "sessions": return .sessionList
        case "session": return .sessionDetail
        case "events", "messages", "tools", "logs": return .eventQuery
        case "stats": return .dbStats
        case "schema": return .dbSchema
        case "read_blob": return .blobRead
        default: return .memorySearch
        }
    }

    static func actionIcon(_ action: String) -> String {
        switch action {
        case "recall": return "sparkles"
        case "search", "memory": return "magnifyingglass"
        case "sessions": return "rectangle.stack"
        case "session": return "rectangle.portrait"
        case "events": return "list.bullet.rectangle"
        case "messages": return "bubble.left.and.bubble.right"
        case "tools": return "wrench.and.screwdriver"
        case "logs": return "doc.text.magnifyingglass"
        case "stats": return "chart.bar"
        case "schema": return "tablecells"
        case "read_blob": return "doc.fill"
        default: return "brain.fill"
        }
    }

    static func actionDisplayName(_ action: String) -> String {
        switch action {
        case "recall": return "Semantic Recall"
        case "search": return "Keyword Search"
        case "memory": return "Memory Search"
        case "sessions": return "Session List"
        case "session": return "Session Detail"
        case "events": return "Event Query"
        case "messages": return "Messages"
        case "tools": return "Tool Calls"
        case "logs": return "Log Query"
        case "stats": return "Database Stats"
        case "schema": return "Database Schema"
        case "read_blob": return "Read Blob"
        default: return action.capitalized
        }
    }

    // MARK: - Memory Entry Parsing

    static func parseMemoryEntries(from result: String) -> [RememberMemoryEntry] {
        var entries: [RememberMemoryEntry] = []

        // Split by double newline to separate entries
        let blocks = result.components(separatedBy: "\n\n")

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Match: "1. content (relevance: 92%)" or "1. content"
            if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)/) {
                let index = Int(match.1) ?? 0
                var content = String(match.2)
                var relevance: Int?

                // Extract relevance from end
                if let relMatch = content.firstMatch(of: /\(relevance:\s*(\d+)%\)\s*$/) {
                    relevance = Int(relMatch.1)
                    content = content.replacingOccurrences(
                        of: "\\s*\\(relevance:\\s*\\d+%\\)\\s*$",
                        with: "",
                        options: .regularExpression
                    )
                }

                // Extract readable text from JSON array entries (e.g. thinking blocks with signatures)
                content = extractReadableContent(from: content)

                // Strip <mark> highlight tags from search results
                content = stripHTMLTags(content)

                // Strip line-number prefixes like "31->" from file content
                content = stripLineNumbers(content)

                // Trim very long content for display
                let displayContent = content.count > 500 ? String(content.prefix(500)) + "..." : content

                entries.append(RememberMemoryEntry(
                    index: index,
                    content: displayContent.trimmingCharacters(in: .whitespacesAndNewlines),
                    relevance: relevance
                ))
            }
        }

        return entries
    }

    /// Extracts readable text from JSON array entries that contain thinking/signature blocks.
    /// Raw format: `[{"signature":"...","thinking":"actual text","type":"thinking"},{"name":"Tool",...}]`
    private static func extractReadableContent(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[{") || trimmed.hasPrefix("[\\n{") else { return content }

        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return content
        }

        var parts: [String] = []
        for item in array {
            // Extract thinking text (most useful content)
            if let thinking = item["thinking"] as? String, !thinking.isEmpty {
                parts.append(thinking)
            }
            // Extract text blocks
            else if let text = item["text"] as? String, !text.isEmpty {
                parts.append(text)
            }
        }

        return parts.isEmpty ? content : parts.joined(separator: "\n")
    }

    private static func stripHTMLTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func stripLineNumbers(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^\\s*\\d+->", with: "", options: .regularExpression)
    }

    // MARK: - Session Parsing

    static func parseSessions(from result: String) -> [RememberSessionEntry] {
        var sessions: [RememberSessionEntry] = []

        for line in result.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }

            let content = String(trimmed.dropFirst(2))
            let parts = content.components(separatedBy: " | ")

            if parts.count >= 1 {
                sessions.append(RememberSessionEntry(
                    sessionId: parts[0].trimmingCharacters(in: .whitespaces),
                    title: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "",
                    date: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                ))
            }
        }

        return sessions
    }

    // MARK: - JSON Entry Parsing

    static func parseJSONEntries(from result: String) -> [String] {
        result.components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Stats Parsing

    static func parseStats(from result: String) -> [RememberStatEntry] {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var stats: [RememberStatEntry] = []

        if let sessions = json["sessions"] {
            stats.append(RememberStatEntry(key: "sessions", label: "Sessions", value: "\(sessions)", icon: "rectangle.stack"))
        }
        if let events = json["events"] {
            stats.append(RememberStatEntry(key: "events", label: "Events", value: "\(events)", icon: "list.bullet.rectangle"))
        }
        if let tokens = json["totalTokens"] {
            stats.append(RememberStatEntry(key: "tokens", label: "Tokens", value: formatNumber(tokens), icon: "number"))
        }
        if let cost = json["totalCost"] {
            stats.append(RememberStatEntry(key: "cost", label: "Total Cost", value: "\(cost)", icon: "dollarsign.circle"))
        }

        return stats
    }

    // MARK: - Date Formatting

    static func formatDate(_ isoDate: String) -> String {
        DateParser.mediumDateTime(isoDate)
    }

    // MARK: - Error Detection

    static func isError(_ result: String) -> Bool {
        let lower = result.lowercased()
        return lower.hasPrefix("error:") || lower.hasPrefix("invalid action") ||
               lower.contains("\"error\"") || lower.hasPrefix("missing required") ||
               lower.hasPrefix("failed to")
    }

    static func isNoResults(_ result: String) -> Bool {
        result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no results found." ||
        result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no results found"
    }

    static func classifyError(_ message: String) -> ErrorClassification {
        let lower = message.lowercased()

        if lower.contains("invalid action") {
            return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Invalid Action", code: "INVALID_ACTION",
                    suggestion: "The action is not recognized. Valid actions: recall, search, sessions, session, events, messages, tools, logs, stats, schema, read_blob.")
        }
        if lower.contains("missing required") || lower.contains("missing") && lower.contains("session_id") {
            return ErrorClassification(icon: "questionmark.circle", title: "Missing Parameter", code: "MISSING_PARAM",
                    suggestion: "A required parameter was not provided. Check the action's required parameters.")
        }
        if lower.contains("not found") {
            return ErrorClassification(icon: "magnifyingglass", title: "Not Found", code: nil,
                    suggestion: "The requested resource was not found in the database.")
        }
        if lower.contains("not available") {
            return ErrorClassification(icon: "xmark.circle", title: "Not Available", code: nil,
                    suggestion: "This feature is not available in the current backend.")
        }

        return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Query Failed", code: nil,
                suggestion: "An error occurred while querying the database.")
    }

    // MARK: - Helpers

    private static func formatNumber(_ value: Any) -> String {
        if let num = value as? Int {
            if num >= 1_000_000 { return String(format: "%.1fM", Double(num) / 1_000_000) }
            if num >= 1_000 { return String(format: "%.1fK", Double(num) / 1_000) }
            return "\(num)"
        }
        return "\(value)"
    }
}
