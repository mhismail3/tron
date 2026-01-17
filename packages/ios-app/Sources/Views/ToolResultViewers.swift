import SwiftUI

// MARK: - Tool Result Router
// Handles core Tron tools: Read, Write, Edit, Bash, Grep, Find, Ls, Browser, AST Grep, Open Browser

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
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tronTextPrimary)

            if !toolDetail.isEmpty {
                Text(toolDetail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }

            Spacer()

            statusBadge

            if let duration = tool.formattedDuration {
                Text(duration)
                    .font(.system(size: 10, design: .monospaced))
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
            .font(.system(size: 11, weight: .medium))
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
        case "grep":
            return ("magnifyingglass", .purple)
        case "find", "glob":
            return ("doc.text.magnifyingglass", .cyan)
        case "ls":
            return ("folder", .yellow)
        case "browser":
            return ("globe", .blue)
        case "astgrep":
            return ("wand.and.stars", .mint)
        case "openbrowser":
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
                .font(.system(size: 11))
                .foregroundStyle(.tronSuccess)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
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
        case "grep": return "Grep"
        case "find": return "Find"
        case "glob": return "Glob"
        case "ls": return "Ls"
        case "browser": return "Browser"
        case "astgrep": return "AST Grep"
        case "openbrowser": return "Open Browser"
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
        case "grep":
            let pattern = extractPattern(from: args)
            let path = extractPath(from: args)
            if !path.isEmpty && path != "." {
                return "\"\(pattern)\" in \(shortenPath(path))"
            }
            return "\"\(pattern)\""
        case "find", "glob":
            return extractPattern(from: args)
        case "ls":
            return extractPath(from: args)
        case "browser":
            return extractBrowserAction(from: args)
        case "astgrep":
            let pattern = extractAstGrepPattern(from: args)
            let path = extractPath(from: args)
            if !path.isEmpty && path != "." {
                return "\"\(pattern)\" in \(shortenPath(path))"
            }
            return "\"\(pattern)\""
        case "openbrowser":
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
        case "grep":
            GrepResultViewer(
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
        case "ls":
            LsResultViewer(
                path: extractPath(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "browser":
            BrowserResultViewer(
                action: extractBrowserAction(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "astgrep":
            AstGrepResultViewer(
                pattern: extractAstGrepPattern(from: tool.arguments),
                result: result,
                isExpanded: $isExpanded
            )
        case "openbrowser":
            OpenBrowserResultViewer(
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

// MARK: - Bash Result Viewer

struct BashResultViewer: View {
    let command: String
    let output: String
    @Binding var isExpanded: Bool

    private var lines: [String] {
        output.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        isExpanded ? lines : Array(lines.prefix(8))
    }

    /// Calculate optimal width for line numbers based on total lines
    private var lineNumWidth: CGFloat {
        let maxNum = lines.count
        let digits = String(maxNum).count
        return CGFloat(max(digits * 8, 14)) // ~8pt per digit, min 14pt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Output lines
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 0) {
                            // Line number
                            Text("\(index + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)

                            // Line content
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: isExpanded ? .infinity : 140)

            // Expand/collapse button
            if lines.count > 8 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more (\(lines.count) lines)")
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

// MARK: - Read Result Viewer

struct ReadResultViewer: View {
    let filePath: String
    let content: String
    @Binding var isExpanded: Bool

    /// Parse lines, stripping server-side line number prefixes like "1→", "42→", "  1\t" etc.
    private var parsedLines: [(lineNum: Int, content: String)] {
        content.components(separatedBy: "\n").enumerated().map { index, line in
            // Check for server-side line number prefix patterns:
            // - "123→content" (arrow character)
            // - "  123\tcontent" (spaces + number + tab, cat -n format)
            // - "123:content" (colon separator)
            if let match = line.firstMatch(of: /^\s*(\d+)[→\t:](.*)/) {
                return (Int(match.1) ?? (index + 1), String(match.2))
            }
            return (index + 1, line)
        }
    }

    private var displayLines: [(lineNum: Int, content: String)] {
        isExpanded ? parsedLines : Array(parsedLines.prefix(12))
    }

    private var fileExtension: String {
        URL(fileURLWithPath: filePath).pathExtension.uppercased()
    }

    private var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    private var languageColor: Color {
        switch fileExtension.lowercased() {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        case "rs": return Color(hex: "#CE412B")
        case "go": return Color(hex: "#00ADD8")
        case "md": return Color(hex: "#083FA1")
        case "json": return Color(hex: "#F5A623")
        case "css", "scss": return Color(hex: "#264DE4")
        case "yaml", "yml": return Color(hex: "#CB171E")
        default: return .tronEmerald
        }
    }

    /// Calculate optimal width for line numbers based on max line number
    private var lineNumWidth: CGFloat {
        let maxNum = parsedLines.last?.lineNum ?? parsedLines.count
        let digits = String(maxNum).count
        return CGFloat(max(digits * 8, 16)) // ~8pt per digit, min 16pt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File info header
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(languageColor)

                Text(fileName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)

                if !fileExtension.isEmpty {
                    Text(fileExtension)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                Text("\(parsedLines.count) lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurface)
            .overlay(
                Rectangle()
                    .fill(languageColor)
                    .frame(width: 3),
                alignment: .leading
            )

            // Content lines
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            // Line number
                            Text("\(line.lineNum)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)

                            // Line content (cleaned)
                            Text(line.content.isEmpty ? " " : line.content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: isExpanded ? .infinity : 200)

            // Expand/collapse button
            if parsedLines.count > 12 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more")
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

// MARK: - Edit Result Viewer (Diff)

struct EditResultViewer: View {
    let filePath: String
    let result: String
    @Binding var isExpanded: Bool

    /// Check if result contains a proper diff format
    private var hasDiffFormat: Bool {
        result.contains("@@") && (result.contains("-") || result.contains("+"))
    }

    /// Extract the success message if present (e.g., "Successfully replaced 1 occurrence...")
    private var successMessage: String? {
        let lines = result.components(separatedBy: "\n")
        if let firstLine = lines.first,
           firstLine.contains("Successfully") || firstLine.contains("successfully") {
            return firstLine
        }
        return nil
    }

    private var diffStats: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in result.components(separatedBy: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed += 1
            }
        }
        return (added, removed)
    }

    private var diffLines: [(type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)] {
        var lines: [(type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)] = []
        var oldLineNum = 0
        var newLineNum = 0
        var inDiff = false

        for line in result.components(separatedBy: "\n") {
            // Skip the "Successfully replaced..." line
            if line.contains("Successfully") || line.contains("successfully") {
                continue
            }

            if line.hasPrefix("@@") {
                inDiff = true
                // Parse hunk header for line numbers
                if let match = line.firstMatch(of: /@@ -(\d+),?\d* \+(\d+),?\d* @@/) {
                    oldLineNum = Int(match.1) ?? 0
                    newLineNum = Int(match.2) ?? 0
                }
                lines.append((.hunk, line, nil, nil))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                lines.append((.addition, String(line.dropFirst()), nil, newLineNum))
                newLineNum += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                lines.append((.deletion, String(line.dropFirst()), oldLineNum, nil))
                oldLineNum += 1
            } else if inDiff && !line.hasPrefix("+++") && !line.hasPrefix("---") && !line.isEmpty {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append((.context, content, oldLineNum, newLineNum))
                oldLineNum += 1
                newLineNum += 1
            }
        }
        return lines
    }

    private var displayLines: [(type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)] {
        isExpanded ? diffLines : Array(diffLines.prefix(15))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File info header with stats
            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)

                Spacer()

                // Stats badges
                if diffStats.added > 0 {
                    Text("+\(diffStats.added)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronSuccess)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronSuccess.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if diffStats.removed > 0 {
                    Text("-\(diffStats.removed)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronError)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronError.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurface)

            // Show diff if available, otherwise show the raw result
            if hasDiffFormat && !diffLines.isEmpty {
                // Diff lines
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(
                                type: line.type,
                                content: line.content,
                                oldLineNum: line.oldNum,
                                newLineNum: line.newNum
                            )
                        }
                    }
                }
                .frame(maxHeight: isExpanded ? .infinity : 280)

                // Expand/collapse button
                if diffLines.count > 15 {
                    Button {
                        withAnimation(.tronFast) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(isExpanded ? "Show less" : "Show more")
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
            } else if !result.isEmpty {
                // Fallback: show raw result text
                Text(result)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

enum DiffLineType {
    case context
    case addition
    case deletion
    case hunk
}

struct DiffLineView: View {
    let type: DiffLineType
    let content: String
    let oldLineNum: Int?
    let newLineNum: Int?

    /// Show the relevant line number (new for additions, old for deletions)
    private var displayLineNum: String {
        if let num = newLineNum ?? oldLineNum {
            return String(num)
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 0) {
            // Line number
            Text(displayLineNum)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(lineNumColor.opacity(0.6))
                .frame(width: 20, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, 6)
                .background(lineNumBackground)

            // Marker
            Text(marker)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 12)

            // Content
            Text(content.isEmpty ? " " : content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(contentColor)
        }
        .frame(minHeight: 16)
        .background(lineBackground)
    }

    private var marker: String {
        switch type {
        case .addition: return "+"
        case .deletion: return "-"
        case .hunk: return ""
        case .context: return ""
        }
    }

    private var lineBackground: Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.1)
        case .deletion: return Color.tronError.opacity(0.1)
        case .hunk: return Color.tronSurface
        case .context: return Color.clear
        }
    }

    private var lineNumBackground: Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.08)
        case .deletion: return Color.tronError.opacity(0.08)
        default: return Color.tronSurface
        }
    }

    private var lineNumColor: Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        default: return .tronTextMuted
        }
    }

    private var markerColor: Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        default: return .tronTextMuted
        }
    }

    private var contentColor: Color {
        switch type {
        case .hunk: return .tronEmerald
        default: return .tronTextPrimary
        }
    }
}

// MARK: - Find Result Viewer (also used for Glob)
// Shows a list of matched file paths

struct FindResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool

    private var files: [String] {
        result.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private var displayFiles: [String] {
        isExpanded ? files : Array(files.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File count header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.cyan)

                Text("\(files.count) files found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // File list
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayFiles, id: \.self) { file in
                    HStack(spacing: 8) {
                        Image(systemName: fileIcon(for: file))
                            .font(.system(size: 10))
                            .foregroundStyle(fileIconColor(for: file))
                            .frame(width: 14)

                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            // Expand/collapse button
            if files.count > 10 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show all \(files.count) files")
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

    private func fileIcon(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go":
            return "doc.text"
        case "json", "yaml", "yml", "xml":
            return "doc.badge.gearshape"
        case "md":
            return "doc.richtext"
        case "css", "scss":
            return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo"
        default:
            return "doc"
        }
    }

    private func fileIconColor(for path: String) -> Color {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        default: return .tronTextMuted
        }
    }
}

// MARK: - Ls Result Viewer
// Shows directory listing with file details
// Supports both custom [D]/[F] format and standard ls -la format

struct LsResultViewer: View {
    let path: String
    let result: String
    @Binding var isExpanded: Bool

    private var entries: [LsEntry] {
        result.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { parseLsEntry($0) }
    }

    private var displayEntries: [LsEntry] {
        isExpanded ? entries : Array(entries.prefix(12))
    }

    /// Parse ls output line - handles both custom [D]/[F] format and standard ls -la
    private func parseLsEntry(_ line: String) -> LsEntry? {
        // Skip "total" line
        if line.hasPrefix("total") { return nil }

        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Try custom [D]/[F] format: [D]  128  Dec 27  2025  dirname/
        // or: [F]  601  Dec 27  2025  filename.ext
        if trimmed.hasPrefix("[D]") || trimmed.hasPrefix("[F]") {
            let isDir = trimmed.hasPrefix("[D]")
            let afterMarker = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let components = afterMarker.split(separator: " ", omittingEmptySubsequences: true)

            // Format: size month day year/time name
            if components.count >= 4 {
                let size = Int(components[0])
                // Name is everything after the date parts (month day year/time)
                let name = components.dropFirst(4).joined(separator: " ")
                if !name.isEmpty {
                    return LsEntry(name: name, isDirectory: isDir, size: size, dateStr: formatDateParts(Array(components[1..<4])))
                }
            }
            // Fallback: just extract the name (last component)
            if let lastName = components.last {
                return LsEntry(name: String(lastName), isDirectory: isDir, size: Int(components.first ?? ""), dateStr: nil)
            }
        }

        // Try standard ls -la format: drwxr-xr-x  5 user staff  160 Jan  4 10:00 name
        let components = line.split(separator: " ", omittingEmptySubsequences: true)
        if components.count >= 9 {
            let permissions = String(components[0])
            let isDir = permissions.hasPrefix("d")
            let size = Int(components[4])
            let name = components.dropFirst(8).joined(separator: " ")
            return LsEntry(name: name, isDirectory: isDir, size: size, dateStr: nil)
        }

        // Simple format - just the name
        return LsEntry(name: trimmed, isDirectory: trimmed.hasSuffix("/"), size: nil, dateStr: nil)
    }

    private func formatDateParts(_ parts: [String.SubSequence]) -> String? {
        guard parts.count >= 3 else { return nil }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)

                Text("\(entries.count) items")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // Directory listing - filename first
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayEntries, id: \.name) { entry in
                    HStack(spacing: 6) {
                        // Icon
                        Image(systemName: entry.isDirectory ? "folder.fill" : entryIcon(for: entry.name))
                            .font(.system(size: 10))
                            .foregroundStyle(entry.isDirectory ? .yellow : entryIconColor(for: entry.name))
                            .frame(width: 14)

                        // Name (first, most prominent)
                        Text(entry.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(entry.isDirectory ? .tronTextPrimary : .tronTextSecondary)
                            .lineLimit(1)

                        Spacer()

                        // Size
                        if let size = entry.size {
                            Text(formatSize(size))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tronTextMuted)
                        }

                        // Date
                        if let dateStr = entry.dateStr {
                            Text(dateStr)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }

            // Expand/collapse button
            if entries.count > 12 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show all \(entries.count) items")
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

    private func entryIcon(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go":
            return "doc.text"
        case "json", "yaml", "yml", "xml":
            return "doc.badge.gearshape"
        case "md":
            return "doc.richtext"
        case "css", "scss":
            return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo"
        case "sh":
            return "terminal"
        case "txt":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }

    private func entryIconColor(for name: String) -> Color {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        case "sh": return .tronEmerald
        case "md": return Color(hex: "#083FA1")
        default: return .tronTextMuted
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)K" }
        return "\(bytes / (1024 * 1024))M"
    }
}

/// Structured ls entry
private struct LsEntry: Identifiable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: Int?
    let dateStr: String?
}

// MARK: - Grep Result Viewer
// Shows search results - just displays raw lines cleanly

struct GrepResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool

    private var lines: [String] {
        result.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private var displayLines: [String] {
        isExpanded ? lines : Array(lines.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Match count header
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)

                Text("\(lines.count) matches")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)

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

            // Results - simple raw display
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .frame(minHeight: 16, alignment: .leading)
                            .padding(.leading, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: isExpanded ? .infinity : 180)

            // Expand/collapse button
            if lines.count > 10 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show all \(lines.count) matches")
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


// MARK: - Write Result Viewer

struct WriteResultViewer: View {
    let filePath: String
    let content: String
    let result: String
    @State private var isExpanded = false

    private var contentLines: [String] {
        content.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        isExpanded ? contentLines : Array(contentLines.prefix(6))
    }

    private var hasContent: Bool {
        !content.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Success message
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronSuccess)

                Text(result)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Content preview (expandable)
            if hasContent {
                VStack(alignment: .leading, spacing: 0) {
                    // Divider
                    Rectangle()
                        .fill(Color.tronBorder.opacity(0.3))
                        .frame(height: 0.5)

                    // Content preview
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                                HStack(spacing: 0) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tronTextMuted.opacity(0.4))
                                        .frame(width: 16, alignment: .trailing)
                                        .padding(.leading, 4)
                                        .padding(.trailing, 8)

                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tronTextMuted)
                                }
                                .frame(minHeight: 15)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: isExpanded ? .infinity : 100)

                    // Expand/collapse button
                    if contentLines.count > 6 {
                        Button {
                            withAnimation(.tronFast) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text(isExpanded ? "Hide content" : "Show all \(contentLines.count) lines")
                                    .font(.system(size: 10, design: .monospaced))
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(.tronTextMuted)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(Color.tronSurface)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Browser Result Viewer

struct BrowserResultViewer: View {
    let action: String
    let result: String
    @Binding var isExpanded: Bool

    private var displayText: String {
        if isExpanded || result.count <= 500 {
            return result
        }
        return String(result.prefix(500)) + "..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if result.count > 500 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.system(size: 11, design: .monospaced))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tronTextMuted)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(Color.tronSurface)
                }
            }
        }
    }
}

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
private struct AstGrepMatch: Identifiable {
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
private struct AstGrepMatchRow: View {
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

// MARK: - Open Browser Result Viewer
// Shows browser open action results

struct OpenBrowserResultViewer: View {
    let url: String
    let result: String
    @Binding var isExpanded: Bool

    /// Unescape JSON escape sequences in strings
    private func unescape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\/", with: "/")
           .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Unescaped URL for display
    private var displayUrl: String {
        unescape(url)
    }

    /// Unescaped result for display
    private var displayResult: String {
        unescape(result)
    }

    /// Parse the result to extract meaningful info
    private var displayInfo: (icon: String, message: String, detail: String?) {
        let lowercased = displayResult.lowercased()

        if lowercased.contains("opening") || lowercased.contains("opened") {
            return ("checkmark.circle.fill", "Opened in browser", displayUrl.isEmpty ? nil : displayUrl)
        } else if lowercased.contains("safari") {
            return ("safari.fill", "Opening in Safari", displayUrl.isEmpty ? nil : displayUrl)
        } else if lowercased.contains("chrome") {
            return ("globe", "Opening in Chrome", displayUrl.isEmpty ? nil : displayUrl)
        } else if lowercased.contains("error") || lowercased.contains("failed") {
            return ("xmark.circle.fill", "Failed to open", displayResult)
        } else {
            // Default: show the result as-is
            return ("safari", "Browser action", nil)
        }
    }

    private var isSuccess: Bool {
        let lowercased = displayResult.lowercased()
        return !lowercased.contains("error") && !lowercased.contains("failed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Status icon
                Image(systemName: displayInfo.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSuccess ? .tronSuccess : .tronError)

                VStack(alignment: .leading, spacing: 2) {
                    // Main message
                    Text(displayInfo.message)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronTextSecondary)

                    // URL or detail
                    if let detail = displayInfo.detail {
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Show full result if different from parsed display
            if !displayResult.isEmpty && displayResult != displayInfo.message && displayResult != displayInfo.detail {
                Rectangle()
                    .fill(Color.tronBorder.opacity(0.3))
                    .frame(height: 0.5)

                Text(isExpanded ? displayResult : String(displayResult.prefix(200)) + (displayResult.count > 200 ? "..." : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if displayResult.count > 200 {
                    Button {
                        withAnimation(.tronFast) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(isExpanded ? "Show less" : "Show more")
                                .font(.system(size: 10, design: .monospaced))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.tronTextMuted)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color.tronSurface)
                    }
                }
            }
        }
    }
}

// MARK: - Generic Result Viewer

struct GenericResultViewer: View {
    let result: String
    @Binding var isExpanded: Bool

    private var displayText: String {
        if isExpanded || result.count <= 500 {
            return result
        }
        return String(result.prefix(500)) + "..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if result.count > 500 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more")
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
