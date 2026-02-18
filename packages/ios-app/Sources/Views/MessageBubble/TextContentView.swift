import SwiftUI

// MARK: - Text Selection Environment Key

/// Environment key to disable text selection during navigation transitions.
/// Prevents EXC_BREAKPOINT in SwiftUI.SDFStyle.distanceRange.getter when
/// the LazyVStack is torn down during a NavigationSplitView pop animation.
private struct TextSelectionDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var textSelectionDisabled: Bool {
        get { self[TextSelectionDisabledKey.self] }
        set { self[TextSelectionDisabledKey.self] = newValue }
    }
}

extension View {
    /// Conditionally enables text selection. When disabled, returns the view unmodified
    /// (no SDF selection infrastructure created). Used to prevent EXC_BREAKPOINT in
    /// SDFStyle.distanceRange.getter during navigation teardown.
    @ViewBuilder
    func selectableText(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}

// MARK: - Table Types

struct MarkdownTable: Equatable {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]
}

enum TableAlignment: Equatable {
    case left
    case center
    case right
}

// MARK: - Text Content View (Terminal-style with Block Markdown)

struct TextContentView: View {
    let text: String
    let role: MessageRole
    @Environment(\.textSelectionDisabled) private var textSelectionDisabled

    private var isUser: Bool { role == .user }

    /// Inline-only markdown with bold fix. Used by other views (ThinkingContentView, etc.)
    @MainActor
    static func markdownAttributedString(from content: String, size: CGFloat = TronTypography.sizeBody) -> AttributedString {
        inlineMarkdown(from: content, size: size)
    }

    /// Parse text into block-level markdown segments
    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if role == .assistant {
                Rectangle()
                    .fill(Color.tronEmerald)
                    .frame(width: 2)
                    .padding(.trailing, 12)
            }

            if isUser {
                StyledSkillMentionText(text: text)
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.userMessageText)
                    .selectableText(!textSelectionDisabled)
                    .lineSpacing(4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isUser ? 0 : 4)
        .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
    }
}

// MARK: - Styled Skill Mention Text (highlights @skillname in user messages)

struct StyledSkillMentionText: View {
    let text: String

    /// Regex pattern for @skillname (alphanumeric and hyphens, followed by space/newline/end)
    /// Uses static closure to safely handle (impossible) regex compilation failure
    private static let skillMentionPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "@([a-zA-Z0-9][a-zA-Z0-9-]*)", options: [])
    }()

    var body: some View {
        buildStyledText()
    }

    /// Build a Text view with @mentions styled differently
    private func buildStyledText() -> Text {
        // If regex failed to compile (should never happen), return plain text
        guard let pattern = Self.skillMentionPattern else {
            return Text(text)
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = pattern.matches(in: text, options: [], range: range)

        if matches.isEmpty {
            return Text(text)
        }

        var result = Text("")
        var lastEnd = 0

        for match in matches {
            // Add text before the match
            if match.range.location > lastEnd {
                let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
                let beforeText = nsText.substring(with: beforeRange)
                result = result + Text(beforeText)
            }

            // Add the @mention with special styling
            let mentionText = nsText.substring(with: match.range)
            result = result + Text(mentionText)
                .foregroundColor(.tronCyan)
                .fontWeight(.medium)

            lastEnd = match.range.location + match.range.length
        }

        // Add remaining text after last match
        if lastEnd < nsText.length {
            let afterRange = NSRange(location: lastEnd, length: nsText.length - lastEnd)
            let afterText = nsText.substring(with: afterRange)
            result = result + Text(afterText)
        }

        return result
    }
}

// MARK: - Markdown Table Parser

struct MarkdownTableParser {
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

        Text(inlineMarkdown(from: content, size: TronTypography.sizeBodySM, weight: isHeader ? .bold : .regular))
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

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
