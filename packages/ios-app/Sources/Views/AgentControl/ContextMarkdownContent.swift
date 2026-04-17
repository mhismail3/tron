import SwiftUI

// MARK: - Markdown Content View (caption-sized block-level markdown for context audit)

@available(iOS 26.0, *)
struct ContextMarkdownContent: View {
    let content: String
    var textColor: Color = .tronTextSecondary

    private let baseSize = TronTypography.sizeCaption  // 10pt — matches previous plain Text()

    @State private var parsedBlocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parsedBlocks) { block in
                compactBlock(block)
            }
        }
        .task(id: content) {
            parsedBlocks = MarkdownBlockParser.parse(content)
        }
    }

    @ViewBuilder
    private func compactBlock(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .header(let level, let content):
            let (size, weight) = headerStyle(for: level)
            Text(inlineMarkdown(from: content, size: size, weight: weight))
                .foregroundStyle(textColor)
                .padding(.top, 2)
        case .paragraph(let content):
            Text(inlineMarkdown(from: content, size: baseSize))
                .foregroundStyle(textColor)
                .lineSpacing(2)
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                Text(code)
                    .font(TronTypography.code(size: TronTypography.sizeXS))
                    .foregroundStyle(textColor)
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, language != nil ? 4 : 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronOverlay(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .blockquote(let content):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.tronBorder)
                    .frame(width: 2)
                Text(inlineMarkdown(from: content, size: baseSize))
                    .foregroundStyle(.tronTextMuted)
                    .lineSpacing(2)
                    .padding(.leading, 6)
            }
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                            .font(TronTypography.sans(size: baseSize))
                            .foregroundStyle(.tronTextMuted)
                        Text(inlineMarkdown(from: item, size: baseSize))
                            .foregroundStyle(textColor)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(TronTypography.sans(size: baseSize, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inlineMarkdown(from: item, size: baseSize))
                            .foregroundStyle(textColor)
                    }
                }
            }
        case .table(let table):
            MarkdownTableView(table: table)
        case .horizontalRule:
            Rectangle()
                .fill(Color.tronBorder)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func headerStyle(for level: Int) -> (size: CGFloat, weight: TronFontLoader.Weight) {
        switch level {
        case 1: return (TronTypography.sizeBodySM, .bold)      // 12pt
        case 2: return (TronTypography.sizeBody2, .bold)       // 11pt
        case 3: return (baseSize, .semibold)                   // 10pt
        default: return (baseSize, .medium)                    // 10pt
        }
    }
}
