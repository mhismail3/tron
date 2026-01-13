import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onSkillTap: ((Skill) -> Void)?

    private var isUserMessage: Bool {
        message.role == .user
    }

    /// Check if we have any metadata to display
    private var hasMetadata: Bool {
        message.tokenUsage != nil ||
        message.shortModelName != nil ||
        message.formattedLatency != nil ||
        message.hasThinking == true
    }

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
            // Show skills above text for user messages (iOS 26 glass chips)
            if let skills = message.skills, !skills.isEmpty {
                if #available(iOS 26.0, *) {
                    MessageSkillChips(skills: skills) { skill in
                        onSkillTap?(skill)
                    }
                } else {
                    // Fallback for older iOS
                    HStack(spacing: 6) {
                        ForEach(skills) { skill in
                            SkillChipFallback(skill: skill) {
                                onSkillTap?(skill)
                            }
                        }
                    }
                }
            }

            // Show attachments above text for user messages
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachedFileThumbnails(attachments: attachments)
            }

            contentView

            // Show enriched metadata badge for assistant messages with metadata
            if !isUserMessage && hasMetadata {
                MessageMetadataBadge(
                    usage: message.tokenUsage,
                    incrementalUsage: message.incrementalTokens,
                    model: message.shortModelName,
                    latency: message.formattedLatency,
                    hasThinking: message.hasThinking
                )
            } else if let usage = message.tokenUsage {
                // Fallback to simple token badge for user messages
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

        case .modelChange(let from, let to):
            ModelChangeNotificationView(from: from, to: to)

        case .reasoningLevelChange(let from, let to):
            ReasoningLevelChangeNotificationView(from: from, to: to)

        case .interrupted:
            InterruptedNotificationView()

        case .transcriptionFailed:
            TranscriptionFailedNotificationView()

        case .transcriptionNoSpeech:
            TranscriptionNoSpeechNotificationView()

        case .compaction(let tokensBefore, let tokensAfter, let reason):
            CompactionNotificationView(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason)

        case .contextCleared(let tokensBefore, let tokensAfter):
            ContextClearedNotificationView(tokensBefore: tokensBefore, tokensAfter: tokensAfter)

        case .messageDeleted(let targetType):
            MessageDeletedNotificationView(targetType: targetType)

        case .attachments(let attachments):
            // Attachments-only message (no text) - show thumbnails
            AttachedFileThumbnails(attachments: attachments)
        }
    }
}

// MARK: - Model Change Notification View (Pill-style in-chat notification)

struct ModelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronEmerald)

            Text("Switched from")
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)

            Text(from.shortModelName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tronTextMuted)

            Text(to.shortModelName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronEmerald)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurface.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Reasoning Level Change Notification View (Pill-style in-chat notification)

struct ReasoningLevelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronEmerald)

            Text("Reasoning")
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)

            Text(from)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tronTextMuted)

            Text(to)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronEmerald)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurface.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Interrupted Notification View (Red pill-style in-chat notification)

struct InterruptedNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)

            Text("Session interrupted")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.red.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Transcription Failed Notification View (Red pill-style in-chat notification)

struct TranscriptionFailedNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)

            Text("Transcription failed")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.red.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - No Speech Detected Notification View (Amber pill-style in-chat notification)

struct TranscriptionNoSpeechNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.orange)

            Text("No speech detected")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.orange.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Compaction Notification View (Cyan pill-style in-chat notification)

struct CompactionNotificationView: View {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String

    private var tokensSaved: Int {
        tokensBefore - tokensAfter
    }

    private var formattedSaved: String {
        if tokensSaved >= 1000 {
            return String(format: "%.1fk", Double(tokensSaved) / 1000.0)
        }
        return "\(tokensSaved)"
    }

    private var compressionPercent: Int {
        guard tokensBefore > 0 else { return 0 }
        return Int(Double(tokensSaved) / Double(tokensBefore) * 100)
    }

    private var reasonDisplay: String {
        switch reason {
        case "pre_turn_guardrail":
            return "auto"
        case "threshold_exceeded":
            return "threshold"
        case "manual":
            return "manual"
        default:
            return reason
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.cyan)

            Text("Context compacted")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.9))

            Text("•")
                .font(.system(size: 8))
                .foregroundStyle(.cyan.opacity(0.5))

            Text("\(formattedSaved) tokens saved")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.7))

            Text("(\(compressionPercent)%)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cyan.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.cyan.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Context Cleared Notification View (Teal pill-style in-chat notification)

struct ContextClearedNotificationView: View {
    let tokensBefore: Int
    let tokensAfter: Int

    private var tokensFreed: Int {
        tokensBefore - tokensAfter
    }

    private var formattedFreed: String {
        if tokensFreed >= 1000 {
            return String(format: "%.1fk", Double(tokensFreed) / 1000.0)
        }
        return "\(tokensFreed)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.teal)

            Text("Context cleared")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.teal.opacity(0.9))

            Text("•")
                .font(.system(size: 8))
                .foregroundStyle(.teal.opacity(0.5))

            Text("\(formattedFreed) tokens freed")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.teal.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.teal.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.teal.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Message Deleted Notification View (Orange pill-style in-chat notification)

struct MessageDeletedNotificationView: View {
    let targetType: String

    private var typeLabel: String {
        switch targetType {
        case "message.user":
            return "user message"
        case "message.assistant":
            return "assistant message"
        case "tool.result":
            return "tool result"
        default:
            return "message"
        }
    }

    private var icon: String {
        switch targetType {
        case "message.user":
            return "person.fill.xmark"
        case "message.assistant":
            return "sparkles"
        case "tool.result":
            return "hammer.fill"
        default:
            return "trash.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronAmber)

            Text("Deleted \(typeLabel) from context")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronAmber.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronAmber.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronAmber.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
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

    /// Calculate column widths based on content
    private var columnWidths: [CGFloat] {
        var widths: [CGFloat] = Array(repeating: 0, count: table.headers.count)

        // Check header widths
        for (index, header) in table.headers.enumerated() {
            widths[index] = max(widths[index], estimateWidth(for: header, isHeader: true))
        }

        // Check all row data
        for row in table.rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], estimateWidth(for: cell, isHeader: false))
            }
        }

        return widths
    }

    /// Estimate width needed for text (monospaced font)
    private func estimateWidth(for text: String, isHeader: Bool) -> CGFloat {
        let charWidth: CGFloat = 7.5 // Approximate char width for 12pt monospaced
        let padding: CGFloat = 20 // Horizontal padding
        let minWidth: CGFloat = 50
        return max(minWidth, CGFloat(text.count) * charWidth + padding)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        tableCellView(
                            header,
                            isHeader: true,
                            column: index,
                            width: columnWidths[safe: index] ?? 80
                        )
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
                        ForEach(0..<table.headers.count, id: \.self) { colIndex in
                            let cell = row[safe: colIndex] ?? ""
                            tableCellView(
                                cell,
                                isHeader: false,
                                column: colIndex,
                                width: columnWidths[safe: colIndex] ?? 80
                            )
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
    private func tableCellView(_ content: String, isHeader: Bool, column: Int, width: CGFloat) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .left
        let isLastColumn = column == table.headers.count - 1

        Text(content)
            .font(.system(size: 12, weight: isHeader ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(isHeader ? .tronTextPrimary : .tronTextSecondary)
            .lineLimit(nil)
            .multilineTextAlignment(textAlignment(for: alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: frameAlignment(for: alignment))
            .overlay(
                Group {
                    if !isLastColumn {
                        Rectangle()
                            .fill(Color.tronBorder.opacity(0.3))
                            .frame(width: 1)
                    }
                },
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

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
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

    /// Extract a short summary from arguments for display (e.g., command for Bash, path for Read)
    private var toolDetail: String {
        guard let args = result.arguments else { return "" }

        // Try to parse JSON and extract the most relevant field
        if let data = args.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // For Bash: show command
            if let command = json["command"] as? String {
                // Truncate long commands
                let truncated = command.count > 30 ? String(command.prefix(30)) + "..." : command
                return truncated
            }
            // For Read/Write/Edit: show file path
            if let path = json["file_path"] as? String ?? json["path"] as? String {
                // Show just filename
                return path.filename
            }
            // For Grep: show pattern
            if let pattern = json["pattern"] as? String {
                return pattern.count > 20 ? String(pattern.prefix(20)) + "..." : pattern
            }
        }
        return ""
    }

    /// Icon configuration based on tool name
    private var toolIconConfig: (name: String, color: Color) {
        guard let toolName = result.toolName?.lowercased() else {
            return (result.isError ? "xmark.circle" : "checkmark.circle", result.isError ? .tronError : .tronSuccess)
        }

        switch toolName {
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
        case "glob":
            return ("doc.text.magnifyingglass", .cyan)
        default:
            return (result.isError ? "xmark.circle" : "checkmark.circle", result.isError ? .tronError : .tronSuccess)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                let (iconName, iconColor) = toolIconConfig
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(result.isError ? .tronError : iconColor)

                // Show tool name if available, otherwise "result" or "error"
                if let toolName = result.toolName {
                    Text(toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronTextPrimary)

                    if !toolDetail.isEmpty {
                        Text(toolDetail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                            .lineLimit(1)
                    }
                } else {
                    Text(result.isError ? "error" : "result")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(result.isError ? .tronError : .tronTextPrimary)
                }

                Spacer()

                // Status badge
                Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(result.isError ? .tronError : .tronSuccess)

                // Duration if available
                if let durationMs = result.durationMs {
                    Text(formatDuration(durationMs))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)
                }
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

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            let seconds = Double(ms) / 1000.0
            return String(format: "%.1fs", seconds)
        }
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

// MARK: - Attached File Thumbnails (displayed above user message text)

struct AttachedFileThumbnails: View {
    let attachments: [Attachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment)
            }
        }
    }
}

/// Individual attachment thumbnail for display in chat messages
private struct AttachmentThumbnail: View {
    let attachment: Attachment

    var body: some View {
        Group {
            if attachment.isImage, let uiImage = UIImage(data: attachment.data) {
                // Image thumbnail
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 1)
                    )
            } else {
                // Document/PDF thumbnail with icon
                VStack(spacing: 2) {
                    Image(systemName: attachment.isPDF ? "doc.fill" : "doc.text.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tronEmerald)

                    if let fileName = attachment.fileName {
                        Text(fileName)
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(attachment.formattedSize)
                        .font(.system(size: 7))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: 56, height: 56)
                .background(Color.tronSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 1)
                )
            }
        }
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

// MARK: - Message Metadata Badge (Enriched Phase 1)

/// Displays comprehensive metadata beneath assistant messages:
/// Token usage, model name, latency, and thinking indicator
struct MessageMetadataBadge: View {
    let usage: TokenUsage?
    /// Incremental tokens (delta from previous turn) for display - preferred over raw usage
    let incrementalUsage: TokenUsage?
    let model: String?
    let latency: String?
    let hasThinking: Bool?

    /// The token usage to display - prefer incremental if available
    private var displayUsage: TokenUsage? {
        incrementalUsage ?? usage
    }

    /// Check if we need a separator before additional metadata
    private var needsSeparator: Bool {
        displayUsage != nil && (model != nil || latency != nil || hasThinking == true)
    }

    /// Check if we need a separator between model and latency
    private var needsModelLatencySeparator: Bool {
        model != nil && latency != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            // Token usage - show incremental if available, otherwise full
            if let usage = displayUsage {
                TokenBadge(usage: usage)
            }

            // Separator after tokens
            if needsSeparator {
                Text("•")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Model name pill
            if let model = model {
                Text(model)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Separator between model and latency
            if needsModelLatencySeparator {
                Text("•")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Latency pill
            if let latency = latency {
                Text(latency)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Thinking indicator (text, not emoji)
            if hasThinking == true {
                Text("Thinking")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronAmber)
            }
        }
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
