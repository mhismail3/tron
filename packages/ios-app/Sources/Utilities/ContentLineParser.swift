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
        var trimmed = content
        while trimmed.last?.isNewline == true { trimmed.removeLast() }
        let rawLines = trimmed.components(separatedBy: "\n")
        var result: [ParsedLine] = []
        var lastLineNum = 0

        for (index, line) in rawLines.enumerated() {
            // Match server-side line number prefixes (from Read tool output)
            if let match = line.firstMatch(of: /^\s*(\d+)[→\t:](.*)/) {
                let num = Int(match.1) ?? (lastLineNum + 1)
                lastLineNum = num
                result.append(ParsedLine(id: index, lineNum: num, content: String(match.2)))
            } else {
                // No server-side prefix — continue from previous line number
                lastLineNum += 1
                result.append(ParsedLine(id: index, lineNum: lastLineNum, content: line))
            }
        }

        return result
    }
}
