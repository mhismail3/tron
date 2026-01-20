import SwiftUI

/// Unified view for displaying content with line numbers
/// Strips server-side line prefixes and displays clean formatted output
struct LineNumberedContentView: View {
    let content: String
    let maxCollapsedLines: Int
    @Binding var isExpanded: Bool

    var fontSize: CGFloat = 11
    var lineNumFontSize: CGFloat = 9
    var maxCollapsedHeight: CGFloat = 200
    var lineHeight: CGFloat = 16
    var showExpandButton: Bool = true

    private var parsedLines: [ContentLineParser.ParsedLine] {
        ContentLineParser.parse(content)
    }

    private var displayLines: [ContentLineParser.ParsedLine] {
        isExpanded ? parsedLines : Array(parsedLines.prefix(maxCollapsedLines))
    }

    /// Calculate optimal width for line numbers based on max line number
    private var lineNumWidth: CGFloat {
        let maxNum = parsedLines.last?.lineNum ?? parsedLines.count
        let digits = String(maxNum).count
        return CGFloat(max(digits * 8, 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayLines) { line in
                        HStack(spacing: 0) {
                            // Line number gutter
                            Text("\(line.lineNum)")
                                .font(TronTypography.mono(size: lineNumFontSize))
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)

                            // Content
                            Text(line.content.isEmpty ? " " : line.content)
                                .font(TronTypography.mono(size: fontSize))
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: lineHeight)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: isExpanded ? .infinity : maxCollapsedHeight)

            // Expand/collapse button
            if showExpandButton && parsedLines.count > maxCollapsedLines {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more (\(parsedLines.count) lines)")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
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

// MARK: - Wrapper with internal state management

/// Wrapper that manages its own expansion state
struct LineNumberedContentViewWithState: View {
    let content: String
    let maxCollapsedLines: Int
    var fontSize: CGFloat = 11
    var lineNumFontSize: CGFloat = 9
    var maxCollapsedHeight: CGFloat = 200
    var lineHeight: CGFloat = 16

    @State private var isExpanded = false

    var body: some View {
        LineNumberedContentView(
            content: content,
            maxCollapsedLines: maxCollapsedLines,
            isExpanded: $isExpanded,
            fontSize: fontSize,
            lineNumFontSize: lineNumFontSize,
            maxCollapsedHeight: maxCollapsedHeight,
            lineHeight: lineHeight
        )
    }
}
