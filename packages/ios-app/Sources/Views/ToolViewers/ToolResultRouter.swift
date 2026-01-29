import SwiftUI

// MARK: - Tool Result Router
// Handles core Tron tools: Read, Write, Edit, Bash, Search, Find, BrowseTheWeb, OpenURL

struct ToolResultRouter: View {
    let tool: ToolUseData
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tool header
            toolHeader

            // Tool-specific result viewer
            if let result = tool.result, !result.isEmpty {
                resultViewer(for: result)
            }
        }
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusBorder, lineWidth: 0.5)
        )
    }

    private var toolHeader: some View {
        HStack(spacing: 8) {
            toolIcon

            Text(displayToolName)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)

            if !toolDetail.isEmpty {
                Text(toolDetail)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }

            Spacer()

            statusBadge

            if let duration = tool.formattedDuration {
                Text(duration)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurfaceElevated)
    }

    // MARK: - Tool Icon (distinct for each tool)

    private var toolIcon: some View {
        let (iconName, iconColor) = toolIconConfig
        return Image(systemName: iconName)
            .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 16)
    }

    private var toolIconConfig: (name: String, color: Color) {
        switch normalizedToolName {
        case "read":
            return ("doc.text", .tronEmerald)
        case "write":
            return ("doc.badge.plus", .tronSuccess)
        case "edit":
            return ("pencil.line", .orange)
        case "bash":
            return ("terminal", .tronEmerald)
        case "search":
            return ("magnifyingglass", .purple)
        case "find", "glob":
            return ("doc.text.magnifyingglass", .cyan)
        case "browsetheweb":
            return ("globe", .blue)
        case "openurl":
            return ("safari", .blue)
        case "askuserquestion":
            return ("questionmark.circle.fill", .tronAmber)
        default:
            return ("gearshape", .tronTextMuted)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        switch tool.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronSuccess)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronError)
        }
    }

    /// Display name - properly capitalized for each tool
    private var displayToolName: String {
        switch normalizedToolName {
        case "read": return "Read"
        case "write": return "Write"
        case "edit": return "Edit"
        case "bash": return "Bash"
        case "search": return "Search"
        case "find": return "Find"
        case "glob": return "Glob"
        case "browsetheweb": return "Browse Web"
        case "openurl": return "Open URL"
        default: return tool.toolName.capitalized
        }
    }

    /// Normalized tool name for routing (lowercase)
    private var normalizedToolName: String {
        tool.toolName.lowercased()
    }

    /// Detail string shown after tool name
    private var toolDetail: String {
        let args = tool.arguments

        switch normalizedToolName {
        case "read":
            return shortenPath(extractFilePath(from: args))
        case "write":
            return shortenPath(extractFilePath(from: args))
        case "edit":
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
        default:
            return ""
        }
    }

    // MARK: - Result Viewer Routing

    @ViewBuilder
    private func resultViewer(for result: String) -> some View {
        switch normalizedToolName {
        case "read":
            ReadResultViewer(
                filePath: extractFilePath(from: tool.arguments),
                content: result,
                isExpanded: $isExpanded
            )
        case "write":
            WriteResultViewer(
                filePath: extractFilePath(from: tool.arguments),
                content: extractContent(from: tool.arguments),
                result: result
            )
        case "edit":
            EditResultViewer(
                filePath: extractFilePath(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "bash":
            BashResultViewer(
                command: extractCommand(from: tool.arguments),
                output: result,
                isExpanded: $isExpanded
            )
        case "search":
            SearchToolViewer(
                pattern: extractPattern(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "find", "glob":
            FindResultViewer(
                pattern: extractPattern(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "browsetheweb":
            BrowserToolViewer(
                action: extractBrowserAction(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "openurl":
            OpenURLResultViewer(
                url: extractOpenBrowserUrl(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        default:
            GenericResultViewer(result: result, isExpanded: $isExpanded)
        }
    }

    private var statusBorder: Color {
        switch tool.status {
        case .running: return .tronInfo.opacity(0.3)
        case .success: return .tronBorder.opacity(0.3)
        case .error: return .tronError.opacity(0.3)
        }
    }

    // MARK: - Argument Parsing Helpers

    private func extractFilePath(from args: String) -> String {
        if let match = args.firstMatch(of: /"file_path"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return ""
    }

    private func extractPath(from args: String) -> String {
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return "."
    }

    private func extractCommand(from args: String) -> String {
        if let match = args.firstMatch(of: /"command"\s*:\s*"([^"]+)"/) {
            return String(match.1).replacingOccurrences(of: "\\n", with: " ")
        }
        return ""
    }

    private func extractPattern(from args: String) -> String {
        if let match = args.firstMatch(of: /"pattern"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return ""
    }

    private func extractContent(from args: String) -> String {
        // Try to extract content field from JSON arguments
        // Handle escaped content in JSON
        if let match = args.firstMatch(of: /"content"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return ""
    }

    /// Shorten a file path to just the filename for display
    private func shortenPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Truncate long commands for the header
    private func truncateCommand(_ cmd: String) -> String {
        guard cmd.count > 40 else { return cmd }
        return String(cmd.prefix(40)) + "..."
    }

    /// Extract browser action from arguments
    private func extractBrowserAction(from args: String) -> String {
        if let match = args.firstMatch(of: /"action"\s*:\s*"([^"]+)"/) {
            let action = String(match.1)
            // Also try to get URL for navigate action
            if action == "navigate", let urlMatch = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
                // Unescape JSON escape sequences in URL
                let url = String(urlMatch.1)
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                return "\(action): \(url)"
            }
            // Get selector for click/fill/type actions
            if ["click", "fill", "type", "select"].contains(action),
               let selectorMatch = args.firstMatch(of: /"selector"\s*:\s*"([^"]+)"/) {
                let selector = String(selectorMatch.1)
                return "\(action): \(selector)"
            }
            return action
        }
        return ""
    }

    /// Extract AST Grep pattern from arguments
    private func extractAstGrepPattern(from args: String) -> String {
        // Try "pattern" field first
        if let match = args.firstMatch(of: /"pattern"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        // Try "rule" field (some AST grep implementations use this)
        if let match = args.firstMatch(of: /"rule"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return ""
    }

    /// Extract Open Browser URL from arguments
    private func extractOpenBrowserUrl(from args: String) -> String {
        if let match = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            // Unescape JSON escape sequences
            let url = String(match.1)
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\\"", with: "\"")
            // Shorten long URLs
            if url.count > 50 {
                return String(url.prefix(50)) + "..."
            }
            return url
        }
        return ""
    }
}

// MARK: - Preview

#Preview("Core Tools") {
    ScrollView {
        VStack(spacing: 16) {
            // 1. Read - Read file contents
            ToolResultRouter(tool: ToolUseData(
                toolName: "Read",
                toolCallId: "read-123",
                arguments: "{\"file_path\": \"/Users/test/example.swift\"}",
                status: .success,
                result: "import Foundation\n\nstruct Example {\n    let name: String\n    var value: Int\n}\n",
                durationMs: 15
            ))

            // 2. Write - Create/overwrite files
            ToolResultRouter(tool: ToolUseData(
                toolName: "Write",
                toolCallId: "write-123",
                arguments: "{\"file_path\": \"/Users/test/config.json\", \"content\": \"{\\n  \\\"name\\\": \\\"MyApp\\\",\\n  \\\"version\\\": \\\"1.0.0\\\",\\n  \\\"debug\\\": true\\n}\"}",
                status: .success,
                result: "Successfully wrote 256 bytes to config.json",
                durationMs: 8
            ))

            // 3. Edit - Make precise edits
            ToolResultRouter(tool: ToolUseData(
                toolName: "Edit",
                toolCallId: "edit-123",
                arguments: "{\"file_path\": \"/Users/test/server.py\"}",
                status: .success,
                result: "@@ -2,3 +2,6 @@\n \"\"\"\n Simple test server.\n-\"\"\"\n+\"\"\"\n+\n+Version: 1.0.0\n+Last modified by: AI\n",
                durationMs: 23
            ))

            // 4. Bash - Execute shell commands
            ToolResultRouter(tool: ToolUseData(
                toolName: "Bash",
                toolCallId: "bash-123",
                arguments: "{\"command\": \"git status --short\"}",
                status: .success,
                result: "M  README.md\nA  src/new-file.ts\n?? temp/",
                durationMs: 45
            ))

            // 5. Grep - Search file contents
            ToolResultRouter(tool: ToolUseData(
                toolName: "Grep",
                toolCallId: "grep-123",
                arguments: "{\"pattern\": \"TODO\", \"path\": \"./src\"}",
                status: .success,
                result: "src/app.ts:42:// TODO: Add error handling\nsrc/utils.ts:18:// TODO: Optimize this function\nsrc/main.ts:7:// TODO: Add logging",
                durationMs: 120
            ))

            // 6. Find - Find files by pattern
            ToolResultRouter(tool: ToolUseData(
                toolName: "Find",
                toolCallId: "find-123",
                arguments: "{\"pattern\": \"**/*.swift\"}",
                status: .success,
                result: "Sources/App/main.swift\nSources/Views/ChatView.swift\nSources/Models/Message.swift\nTests/AppTests.swift",
                durationMs: 35
            ))

            // 7. Ls - List directory contents
            ToolResultRouter(tool: ToolUseData(
                toolName: "Ls",
                toolCallId: "ls-123",
                arguments: "{\"path\": \"./src\"}",
                status: .success,
                result: "drwxr-xr-x  5 user staff  160 Jan  4 10:00 components\ndrwxr-xr-x  3 user staff   96 Jan  4 09:30 utils\n-rw-r--r--  1 user staff 1234 Jan  4 10:00 app.ts\n-rw-r--r--  1 user staff  567 Jan  4 09:00 index.ts",
                durationMs: 12
            ))

            // 8. AST Grep - with matches
            ToolResultRouter(tool: ToolUseData(
                toolName: "Astgrep",
                toolCallId: "astgrep-123",
                arguments: "{\"pattern\": \"const $NAME = $VALUE\"}",
                status: .success,
                result: "/Users/moose/Downloads/test/test_code.js:\n  6:0: const user = \"Moose\";\n    captured: VALUE=\"Moose\", NAME=\"user\"",
                durationMs: 21
            ))

            // 9. AST Grep - no matches
            ToolResultRouter(tool: ToolUseData(
                toolName: "Astgrep",
                toolCallId: "astgrep-empty",
                arguments: "{\"pattern\": \"async function $FN\"}",
                status: .success,
                result: "Found 0 matches in 0 files",
                durationMs: 13
            ))

            // 10. Open Browser - success
            ToolResultRouter(tool: ToolUseData(
                toolName: "Openbrowser",
                toolCallId: "browser-123",
                arguments: "{\"url\": \"https://example.com\"}",
                status: .success,
                result: "Opening https://example.com in Safari",
                durationMs: 0
            ))

            // Also show running and error states
            ToolResultRouter(tool: ToolUseData(
                toolName: "Bash",
                toolCallId: "bash-running",
                arguments: "{\"command\": \"npm install\"}",
                status: .running,
                result: nil,
                durationMs: nil
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Read",
                toolCallId: "read-error",
                arguments: "{\"file_path\": \"/nonexistent/file.txt\"}",
                status: .error,
                result: "Error: File not found",
                durationMs: 5
            ))
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
