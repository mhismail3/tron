import SwiftUI

enum MarkdownListLayout {
    /// A bullet only reserves enough room for its glyph. Ordered markers can
    /// grow beyond this minimum when their number needs more horizontal space.
    static let minimumMarkerWidth: CGFloat = 8
    static let markerSpacing: CGFloat = 5
    /// Every nested bullet begins at the preceding level's minimum text origin.
    static let depthIndent: CGFloat = minimumMarkerWidth + markerSpacing

    static func leadingIndent(forDepth depth: Int) -> CGFloat {
        CGFloat(max(depth, 0)) * depthIndent
    }

    static func minimumContentLeadingIndent(forDepth depth: Int) -> CGFloat {
        leadingIndent(forDepth: depth) + minimumMarkerWidth + markerSpacing
    }
}

// MARK: - Inline Markdown Helper

/// Parses inline markdown and fixes bold rendering by using explicit variable font weights
/// instead of relying on SwiftUI's automatic bold synthesis (which conflicts with custom variable fonts).
@MainActor
func inlineMarkdown(from content: String, size: CGFloat = TronTypography.sizeBody, weight: TronFontLoader.Weight = .regular) -> AttributedString {
    guard var attributed = try? AttributedString(
        markdown: content,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) else {
        return AttributedString(content)
    }

    let boldFont = Font(TronFontLoader.createUIFont(size: size, weight: .bold))
    let baseFont = Font(TronFontLoader.createUIFont(size: size, weight: weight))

    // Collect bold ranges first, then mutate (avoids modifying during iteration)
    var boldRanges: [Range<AttributedString.Index>] = []
    for run in attributed.runs {
        if let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
            boldRanges.append(run.range)
        }
    }

    for range in boldRanges {
        attributed[range].font = boldFont
        attributed[range].inlinePresentationIntent?.remove(.stronglyEmphasized)
    }

    // Set base font on all runs that don't have an explicit font yet
    var unsetRanges: [Range<AttributedString.Index>] = []
    for run in attributed.runs where run.font == nil {
        unsetRanges.append(run.range)
    }
    for range in unsetRanges {
        attributed[range].font = baseFont
    }

    return attributed
}

// MARK: - Block Rendering View

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var textColor: Color = .assistantMessageText
    var codeBlockBackground: Color = .tronSurfaceElevated
    @Environment(\.textSelectionDisabled) private var textSelectionDisabled

    var body: some View {
        switch block.kind {
        case .header(let level, let content):
            headerView(level: level, content: content)
        case .paragraph(let content):
            paragraphView(content: content)
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        case .blockquote(let content):
            blockquoteView(content: content)
        case .list(let items):
            listView(items: items)
        case .table(let table):
            MarkdownTableView(table: table)
        case .horizontalRule:
            horizontalRuleView
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerView(level: Int, content: String) -> some View {
        let (size, weight, topPadding) = headerStyle(for: level)
        Text(inlineMarkdown(from: content, size: size, weight: weight))
            .foregroundStyle(textColor)
            .selectableText(!textSelectionDisabled)
            .lineSpacing(2)
            .padding(.top, topPadding)
    }

    private func headerStyle(for level: Int) -> (size: CGFloat, weight: TronFontLoader.Weight, topPadding: CGFloat) {
        switch level {
        case 1: return (TronTypography.sizeXL, .bold, 12)
        case 2: return (TronTypography.sizeLargeTitle, .bold, 10)
        case 3: return (TronTypography.sizeTitle, .semibold, 8)
        case 4: return (TronTypography.sizeBody, .semibold, 4)
        default: return (TronTypography.sizeBodySM, .semibold, 4)
        }
    }

    // MARK: - Paragraph

    @ViewBuilder
    private func paragraphView(content: String) -> some View {
        Text(inlineMarkdown(from: content))
            .foregroundStyle(textColor)
            .selectableText(!textSelectionDisabled)
            .lineSpacing(4)
    }

    // MARK: - Code Block

    @ViewBuilder
    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            Text(code)
                .font(TronTypography.code(size: TronTypography.sizeBody3))
                .foregroundStyle(textColor)
                .selectableText(!textSelectionDisabled)
                .lineSpacing(3)
                .padding(.horizontal, 12)
                .padding(.vertical, language != nil ? 8 : 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Blockquote

    @ViewBuilder
    private func blockquoteView(content: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.tronBorder)
                .frame(width: 3)

            Text(inlineMarkdown(from: content))
                .foregroundStyle(.tronTextSecondary)
                .selectableText(!textSelectionDisabled)
                .lineSpacing(4)
                .padding(.leading, 10)
        }
    }

    // MARK: - List

    @ViewBuilder
    private func listView(items: [MarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: MarkdownListLayout.markerSpacing) {
                    Text(markerText(for: item.marker))
                        .font(Font(TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .regular)))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: true, vertical: false)
                        // Keep ordinary bullets compact while allowing ordered
                        // markers such as "10." to occupy their natural width.
                        .frame(
                            minWidth: MarkdownListLayout.minimumMarkerWidth,
                            alignment: .leading
                        )
                    Text(inlineMarkdown(from: item.content))
                        .foregroundStyle(textColor)
                        .selectableText(!textSelectionDisabled)
                        .lineSpacing(4)
                }
                // Root markers begin on the message's leading edge. Only actual
                // nesting adds indentation, so list depth remains stable for
                // ordered, unordered, and mixed lists.
                .padding(.leading, MarkdownListLayout.leadingIndent(forDepth: item.depth))
            }
        }
    }

    private func markerText(for marker: MarkdownListItem.Marker) -> String {
        switch marker {
        case .unordered:
            return "\u{2022}"
        case .ordered(let number):
            return "\(number)."
        }
    }

    // MARK: - Horizontal Rule

    private var horizontalRuleView: some View {
        Rectangle()
            .fill(Color.tronBorder)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}
