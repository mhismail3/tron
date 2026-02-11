import SwiftUI

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
    @Environment(\.textSelectionDisabled) private var textSelectionDisabled

    var body: some View {
        switch block {
        case .header(let level, let content):
            headerView(level: level, content: content)
        case .paragraph(let content):
            paragraphView(content: content)
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        case .blockquote(let content):
            blockquoteView(content: content)
        case .unorderedList(let items):
            unorderedListView(items: items)
        case .orderedList(let items):
            orderedListView(items: items)
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
            .foregroundStyle(.assistantMessageText)
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
            .foregroundStyle(.assistantMessageText)
            .selectableText(!textSelectionDisabled)
            .lineSpacing(4)
    }

    // MARK: - Code Block

    @ViewBuilder
    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            Text(code)
                .font(TronTypography.codeBlock)
                .foregroundStyle(.assistantMessageText)
                .selectableText(!textSelectionDisabled)
                .lineSpacing(3)
                .padding(.horizontal, 12)
                .padding(.vertical, language != nil ? 8 : 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tronSurfaceElevated)
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

    // MARK: - Unordered List

    @ViewBuilder
    private func unorderedListView(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}")
                        .font(Font(TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .regular)))
                        .foregroundStyle(.tronTextSecondary)
                    Text(inlineMarkdown(from: item))
                        .foregroundStyle(.assistantMessageText)
                        .selectableText(!textSelectionDisabled)
                        .lineSpacing(4)
                }
                .padding(.leading, 8)
            }
        }
    }

    // MARK: - Ordered List

    @ViewBuilder
    private func orderedListView(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(Font(TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .medium)))
                        .foregroundStyle(.tronTextSecondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    Text(inlineMarkdown(from: item))
                        .foregroundStyle(.assistantMessageText)
                        .selectableText(!textSelectionDisabled)
                        .lineSpacing(4)
                }
                .padding(.leading, 8)
            }
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
