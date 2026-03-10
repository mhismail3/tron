import Foundation

// MARK: - Search Result Parser

/// Parses Search/Grep tool output into structured, file-grouped results.
enum SearchResultParser {

    /// Parse the raw result string into file groups.
    /// Each line format: `file:lineNum: content` or `file:lineNum:content`
    static func parse(_ result: String) -> [SearchFileGroup] {
        let lines = result.components(separatedBy: "\n")
        var groups: [String: [SearchMatch]] = [:]
        var groupOrder: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip metadata lines
            if trimmed.hasPrefix("No matches found") { continue }
            if trimmed.hasPrefix("[Showing") { continue }
            if trimmed.hasPrefix("...") { continue }

            if let match = parseLine(trimmed) {
                if groups[match.filePath] == nil {
                    groupOrder.append(match.filePath)
                    groups[match.filePath] = []
                }
                groups[match.filePath]?.append(match.match)
            }
        }

        return groupOrder.compactMap { path in
            guard let matches = groups[path] else { return nil }
            return SearchFileGroup(filePath: path, matches: matches)
        }
    }

    /// Parse a single line in `file:line: content` format.
    private static func parseLine(_ line: String) -> (filePath: String, match: SearchMatch)? {
        // Pattern: file_path:line_number: content
        // Need to handle paths with colons (e.g., Windows, but unlikely in this context)
        // Strategy: find the first `:digits:` pattern
        guard let colonMatch = line.firstMatch(of: /^(.+?):(\d+):(.*)$/) else {
            return nil
        }

        let filePath = String(colonMatch.1)
        let lineNum = Int(colonMatch.2)
        let content = String(colonMatch.3)
        // Strip leading space if present (ripgrep adds a space after the second colon)
        let trimmedContent = content.hasPrefix(" ") ? String(content.dropFirst()) : content

        return (filePath, SearchMatch(lineNumber: lineNum, content: trimmedContent))
    }

    /// Calculate line number gutter width based on the highest line number.
    static func lineNumberWidth(for matches: [SearchMatch]) -> CGFloat {
        let maxNum = matches.compactMap(\.lineNumber).max() ?? 0
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 16))
    }
}

/// A group of search matches within a single file.
struct SearchFileGroup: Equatable {
    let filePath: String
    let matches: [SearchMatch]
}

/// A single search match: line number + content.
struct SearchMatch: Equatable {
    let lineNumber: Int?
    let content: String
}
