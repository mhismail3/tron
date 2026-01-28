import SwiftUI

// MARK: - AST Grep Result Viewer
// Shows AST pattern matching results with file locations and matched code

struct AstGrepResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    /// Parse AST grep result into structured matches
    private var matches: [AstGrepMatch] {
        parseAstGrepResult(result)
    }

    /// Check if result indicates no matches found
    private var isNoMatches: Bool {
        result.lowercased().contains("found 0 matches") ||
        result.lowercased().contains("no matches") ||
        matches.isEmpty && !result.isEmpty
    }

    /// Parse AST grep output format
    /// Example formats:
    /// - "/path/to/file.js:\n  6:0: const user = \"Moose\";\n    captured: VALUE=\"Moose\", NAME=\"user\""
    /// - "Found 0 matches in 0 files"
    private func parseAstGrepResult(_ text: String) -> [AstGrepMatch] {
        var results: [AstGrepMatch] = []
        let lines = text.components(separatedBy: "\n")
        var currentFile: String?
        var currentMatch: (line: Int, col: Int, code: String, captured: String?)?

        for line in lines {
            // Skip empty lines
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Check for file path line (ends with colon or has file extension pattern)
            if line.hasSuffix(":") && (line.contains("/") || line.contains("\\")) {
                // Save previous match if exists
                if let file = currentFile, let match = currentMatch {
                    results.append(AstGrepMatch(
                        filePath: file,
                        line: match.line,
                        column: match.col,
                        matchedCode: match.code,
                        captured: match.captured
                    ))
                }
                currentFile = String(line.dropLast())
                currentMatch = nil
            }
            // Check for line:col: code pattern
            else if let lineMatch = line.firstMatch(of: /^\s*(\d+):(\d+):\s*(.*)/) {
                // Save previous match if exists
                if let file = currentFile, let match = currentMatch {
                    results.append(AstGrepMatch(
                        filePath: file,
                        line: match.line,
                        column: match.col,
                        matchedCode: match.code,
                        captured: match.captured
                    ))
                }
                currentMatch = (
                    line: Int(lineMatch.1) ?? 0,
                    col: Int(lineMatch.2) ?? 0,
                    code: String(lineMatch.3),
                    captured: nil
                )
            }
            // Check for captured variables line
            else if line.trimmingCharacters(in: .whitespaces).hasPrefix("captured:") {
                if var match = currentMatch {
                    match.captured = line.trimmingCharacters(in: .whitespaces)
                    currentMatch = match
                }
            }
        }

        // Don't forget the last match
        if let file = currentFile, let match = currentMatch {
            results.append(AstGrepMatch(
                filePath: file,
                line: match.line,
                column: match.col,
                matchedCode: match.code,
                captured: match.captured
            ))
        }

        return results
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with match count
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.mint)

                if isNoMatches {
                    Text("No matches found")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                } else {
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }

                if !pattern.isEmpty {
                    Text("for \"\(pattern)\"")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            if isNoMatches && matches.isEmpty {
                // Show raw result for "no matches" messages
                Text(result)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                // Match list - show all
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { match in
                        AstGrepMatchRow(match: match)
                    }
                }
            }
        }
    }
}

/// A single AST grep match
struct AstGrepMatch: Identifiable {
    let id = UUID()
    let filePath: String
    let line: Int
    let column: Int
    let matchedCode: String
    let captured: String?

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

/// Row view for a single AST grep match
struct AstGrepMatchRow: View {
    let match: AstGrepMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // File and location
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(TronTypography.pill)
                    .foregroundStyle(.tronTextMuted)

                Text(match.fileName)
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronTextSecondary)

                Text(":\(match.line):\(match.column)")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }

            // Matched code
            Text(match.matchedCode)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.mint)
                .padding(.leading, 14)

            // Captured variables if present
            if let captured = match.captured {
                Text(captured)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tronSurface.opacity(0.3))
    }
}
