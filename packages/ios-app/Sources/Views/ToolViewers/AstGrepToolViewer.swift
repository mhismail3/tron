import SwiftUI

// MARK: - AST Grep Result Viewer
// Shows AST pattern matching results with file locations and matched code

struct AstGrepResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool

    /// Parse AST grep result into structured matches
    private var matches: [AstGrepMatch] {
        parseAstGrepResult(result)
    }

    private var displayMatches: [AstGrepMatch] {
        isExpanded ? matches : Array(matches.prefix(5))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.mint)

                if isNoMatches {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)
                } else {
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)
                }

                if !pattern.isEmpty {
                    Text("for \"\(pattern)\"")
                        .font(.system(size: 10, design: .monospaced))
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                // Match list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayMatches) { match in
                        AstGrepMatchRow(match: match)
                    }
                }

                // Expand/collapse button
                if matches.count > 5 {
                    Button {
                        withAnimation(.tronFast) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(isExpanded ? "Show less" : "Show all \(matches.count) matches")
                                .font(.system(size: 11, design: .monospaced))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.tronTextMuted)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.tronSurface)
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
                    .font(.system(size: 9))
                    .foregroundStyle(.tronTextMuted)

                Text(match.fileName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)

                Text(":\(match.line):\(match.column)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Matched code
            Text(match.matchedCode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.mint)
                .padding(.leading, 14)

            // Captured variables if present
            if let captured = match.captured {
                Text(captured)
                    .font(.system(size: 10, design: .monospaced))
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
