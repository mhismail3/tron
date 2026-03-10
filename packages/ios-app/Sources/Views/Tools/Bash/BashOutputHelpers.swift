import Foundation

// MARK: - Bash Output Helpers

/// Utility functions for cleaning and formatting Bash command output for display.
enum BashOutputHelpers {

    /// Maximum characters to display per line before visual truncation.
    static let maxLineDisplayLength = 500

    /// Lines of output above which visual collapsing kicks in.
    static let collapseThreshold = 150

    /// Number of leading lines to show when collapsed.
    static let headLines = 100

    /// Number of trailing lines to show when collapsed.
    static let tailLines = 30

    /// Strip ANSI escape codes (colors, formatting) from terminal output.
    static func stripAnsiCodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    /// Strip the iOS-side truncation marker from result text.
    static func stripTruncationMarker(_ text: String) -> String {
        // Handle various truncation message formats
        var result = text
        if let range = result.range(of: "\n\n... [Output truncated for performance]") {
            result = String(result[..<range.lowerBound])
        }
        if let range = result.range(of: "\n... [Output truncated") {
            result = String(result[..<range.lowerBound])
        }
        return result
    }

    /// Full cleaning pipeline: strip truncation markers, ANSI codes.
    static func cleanForDisplay(_ text: String) -> String {
        let stripped = stripTruncationMarker(text)
        return stripAnsiCodes(stripped)
    }

    /// Cap a line's display length, preserving the full text for copy operations.
    static func capLineLength(_ line: String, maxLength: Int = maxLineDisplayLength) -> String {
        if line.count > maxLength {
            return String(line.prefix(maxLength)) + " ..."
        }
        return line.isEmpty ? " " : line
    }

    /// Extract exit code from error result text (e.g., "Command failed with exit code 1:")
    static func extractExitCode(from result: String?) -> Int? {
        guard let result else { return nil }
        if let match = result.firstMatch(of: /exit code (\d+)/) {
            return Int(match.1)
        }
        return nil
    }

    /// Calculate line number gutter width based on total line count.
    static func lineNumberWidth(lineCount: Int) -> CGFloat {
        let digits = max(String(lineCount).count, 1)
        return CGFloat(max(digits * 8, 16))
    }

    /// Produce a collapsed view: first N lines + last M lines, with indices preserved.
    static func collapsedLines(from lines: [String]) -> [(index: Int, content: String)] {
        guard lines.count > collapseThreshold else {
            return lines.enumerated().map { ($0.offset, $0.element) }
        }
        var result: [(index: Int, content: String)] = []
        for i in 0..<headLines {
            result.append((i, lines[i]))
        }
        let tailStart = lines.count - tailLines
        for i in tailStart..<lines.count {
            result.append((i, lines[i]))
        }
        return result
    }
}
