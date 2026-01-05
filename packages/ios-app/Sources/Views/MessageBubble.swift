import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage

    private var isUserMessage: Bool {
        message.role == .user
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            contentView

            if let usage = message.tokenUsage {
                TokenBadge(usage: usage)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            TextContentView(text: text, role: message.role)

        case .streaming(let text):
            StreamingContentView(text: text)

        case .thinking(let visible, let isExpanded):
            ThinkingContentView(content: visible, isExpanded: isExpanded)

        case .toolUse(let tool):
            ToolResultRouter(tool: tool)

        case .toolResult(let result):
            StandaloneToolResultView(result: result)

        case .error(let errorMessage):
            ErrorContentView(message: errorMessage)

        case .images(let images):
            ImagesContentView(images: images)
        }
    }
}

// MARK: - Text Content View (Terminal-style with Table Support)

struct TextContentView: View {
    let text: String
    let role: MessageRole

    private var isUser: Bool { role == .user }

    /// Parse text into segments (tables and normal text)
    private var segments: [TextSegment] {
        MarkdownTableParser.parseSegments(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Green vertical accent line for assistant messages (matching web UI)
            if role == .assistant {
                Rectangle()
                    .fill(Color.tronEmerald)
                    .frame(width: 2)
                    .padding(.trailing, 12)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let content):
                        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(LocalizedStringKey(content))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(isUser ? .tronEmerald : .tronTextPrimary)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                        }
                    case .table(let table):
                        MarkdownTableView(table: table)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isUser ? 0 : 4)
        .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
    }
}

// MARK: - Markdown Table Parser

enum TextSegment {
    case text(String)
    case table(MarkdownTable)
}

struct MarkdownTable {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]
}

enum TableAlignment {
    case left
    case center
    case right
}

struct MarkdownTableParser {
    /// Parse text into alternating segments of regular text and tables
    static func parseSegments(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        let lines = text.components(separatedBy: "\n")
        var currentText = ""
        var tableLines: [String] = []
        var inTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isTableLine(trimmed) {
                if !inTable {
                    // Starting a new table, save any preceding text
                    if !currentText.isEmpty {
                        segments.append(.text(currentText))
                        currentText = ""
                    }
                    inTable = true
                }
                tableLines.append(trimmed)
            } else {
                if inTable {
                    // End of table, parse and save it
                    if let table = parseTable(tableLines) {
                        segments.append(.table(table))
                    } else {
                        // Failed to parse as table, treat as regular text
                        currentText += tableLines.joined(separator: "\n") + "\n"
                    }
                    tableLines = []
                    inTable = false
                }
                currentText += line + "\n"
            }
        }

        // Handle any remaining content
        if inTable && !tableLines.isEmpty {
            if let table = parseTable(tableLines) {
                segments.append(.table(table))
            } else {
                currentText += tableLines.joined(separator: "\n")
            }
        }

        if !currentText.isEmpty {
            // Remove trailing newline
            let trimmed = currentText.hasSuffix("\n") ? String(currentText.dropLast()) : currentText
            if !trimmed.isEmpty {
                segments.append(.text(trimmed))
            }
        }

        return segments
    }

    /// Check if a line looks like part of a markdown table
    static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Must contain pipes and either be a separator row or content row
        guard trimmed.contains("|") else { return false }

        // Separator row: |---|---|
        if trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
            return true
        }

        // Content row: must have at least one pipe
        return trimmed.hasPrefix("|") || trimmed.hasSuffix("|") || trimmed.contains(" | ")
    }

    /// Parse a set of table lines into a structured table
    static func parseTable(_ lines: [String]) -> MarkdownTable? {
        guard lines.count >= 2 else { return nil }

        // Parse header row (first line)
        let headerLine = lines[0]
        let headers = parseCells(headerLine)
        guard !headers.isEmpty else { return nil }

        // Find separator row (should be second line)
        var separatorIndex = 1
        while separatorIndex < lines.count {
            let sep = lines[separatorIndex]
            if sep.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                break
            }
            separatorIndex += 1
        }

        guard separatorIndex < lines.count else { return nil }

        // Parse alignments from separator
        let alignments = parseAlignments(lines[separatorIndex], columnCount: headers.count)

        // Parse data rows (after separator)
        var rows: [[String]] = []
        for i in (separatorIndex + 1)..<lines.count {
            let cells = parseCells(lines[i])
            if !cells.isEmpty {
                // Pad or truncate to match header count
                var row = cells
                while row.count < headers.count {
                    row.append("")
                }
                rows.append(Array(row.prefix(headers.count)))
            }
        }

        return MarkdownTable(headers: headers, rows: rows, alignments: alignments)
    }

    /// Parse cells from a table row
    static func parseCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)

        // Remove leading/trailing pipes
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }

        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parse column alignments from separator row
    static func parseAlignments(_ separatorLine: String, columnCount: Int) -> [TableAlignment] {
        let cells = parseCells(separatorLine)
        var alignments: [TableAlignment] = []

        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") {
                alignments.append(.center)
            } else if trimmed.hasSuffix(":") {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }

        // Pad with left alignment if needed
        while alignments.count < columnCount {
            alignments.append(.left)
        }

        return alignments
    }
}

// MARK: - Markdown Table View

struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        tableCellView(header, isHeader: true, column: index)
                    }
                }
                .background(Color.tronSurfaceElevated)

                // Separator
                Rectangle()
                    .fill(Color.tronBorder)
                    .frame(height: 1)

                // Data rows
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            tableCellView(cell, isHeader: false, column: colIndex)
                        }
                    }
                    .background(rowIndex % 2 == 0 ? Color.tronSurface.opacity(0.3) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.tronBorder.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func tableCellView(_ content: String, isHeader: Bool, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .left

        Text(content)
            .font(.system(size: 12, weight: isHeader ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(isHeader ? .tronTextPrimary : .tronTextSecondary)
            .lineLimit(nil)
            .multilineTextAlignment(textAlignment(for: alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 60, alignment: frameAlignment(for: alignment))
            .overlay(
                Rectangle()
                    .fill(Color.tronBorder.opacity(0.3))
                    .frame(width: 1),
                alignment: .trailing
            )
    }

    private func textAlignment(for alignment: TableAlignment) -> TextAlignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frameAlignment(for alignment: TableAlignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

// MARK: - Streaming Content View (Terminal-style)

struct StreamingContentView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Green vertical accent line (matching web UI)
            Rectangle()
                .fill(Color.tronEmerald)
                .frame(width: 2)
                .padding(.trailing, 12)

            HStack(alignment: .bottom, spacing: 2) {
                if text.isEmpty {
                    Text(" ")
                        .font(.system(size: 14, design: .monospaced))
                } else {
                    Text(LocalizedStringKey(text))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.tronTextPrimary)
                        .lineSpacing(4)
                }

                StreamingCursor()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thinking Content View

struct ThinkingContentView: View {
    let content: String
    let isExpanded: Bool

    @State private var expanded: Bool

    init(content: String, isExpanded: Bool) {
        self.content = content
        self.isExpanded = isExpanded
        self._expanded = State(initialValue: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.tronStandard) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    TronIconView(icon: .thinking, size: 12, color: .tronTextMuted)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextMuted)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            if expanded {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .italic()
            }
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Standalone Tool Result View (for .toolResult content type)

struct StandaloneToolResultView: View {
    let result: ToolResultData
    @State private var isExpanded = false

    private var lines: [String] {
        result.content.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        isExpanded ? lines : Array(lines.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: result.isError ? "xmark" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(result.isError ? .tronError : .tronSuccess)

                Text(result.isError ? "error" : "result")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(result.isError ? .tronError : .tronTextPrimary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurfaceElevated)

            // Content lines
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 0) {
                            // Line number
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tronTextMuted)
                                .frame(width: 32, alignment: .trailing)
                                .padding(.trailing, 8)
                                .background(Color.tronSurface)

                            // Line content
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: 18)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: isExpanded ? .infinity : 160)

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
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(result.isError ? Color.tronError.opacity(0.3) : Color.tronBorder.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Error Content View (Terminal-style)

struct ErrorContentView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tronError)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(10)
        .background(Color.tronError.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.tronError.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Images Content View (Terminal-style)

struct ImagesContentView: View {
    let images: [ImageContent]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.tronBorder.opacity(0.5), lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(4)
    }
}

// MARK: - Token Badge (Terminal-style)

struct TokenBadge: View {
    let usage: TokenUsage

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .medium))
                Text(usage.formattedInput)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .medium))
                Text(usage.formattedOutput)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tronTextMuted)
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            MessageBubble(message: .user("Hello, can you help me?"))
            MessageBubble(message: .assistant("Of course! I'd be happy to help."))

            // Test markdown table rendering
            MessageBubble(message: .assistant("""
            All tools working! Here's a summary:

            | Tool | Status | What it did |
            |------|--------|-------------|
            | ls | ✅ | Listed 8 files/folders |
            | read | ✅ | Read README.md |
            | edit | ✅ | Added a test comment |
            | grep | ✅ | Found 5 functions |
            | bash | ✅ | Ran echo command |

            Everything's working as expected!
            """))

            MessageBubble(message: .streaming("I'm currently typing..."))
            MessageBubble(message: .error("Something went wrong"))
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
