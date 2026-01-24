import Foundation

/// Utility for parsing content with server-side line number prefixes
/// Centralizes the logic from ReadResultViewer for reuse across all viewers
struct ContentLineParser {
    struct ParsedLine: Identifiable {
        let id: Int
        let lineNum: Int
        let content: String
    }

    /// Parse content, stripping server-side line number prefixes
    /// Handles patterns: "123→content", "  123\tcontent", "123:content"
    static func parse(_ content: String) -> [ParsedLine] {
        content.components(separatedBy: "\n").enumerated().map { index, line in
            // Match server-side line number prefixes (from Read tool output)
            if let match = line.firstMatch(of: /^\s*(\d+)[→\t:](.*)/) {
                return ParsedLine(
                    id: index,
                    lineNum: Int(match.1) ?? (index + 1),
                    content: String(match.2)
                )
            }
            // No server-side prefix - use sequential numbering
            return ParsedLine(id: index, lineNum: index + 1, content: line)
        }
    }
}
