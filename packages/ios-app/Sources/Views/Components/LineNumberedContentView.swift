import SwiftUI

/// Unified view for displaying content with line numbers
/// Strips server-side line prefixes and displays clean formatted output
struct LineNumberedContentView: View {
    let content: String
    let maxCollapsedLines: Int  // Kept for API compatibility, but unused
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    var fontSize: CGFloat = 11
    var lineNumFontSize: CGFloat = 9
    var maxCollapsedHeight: CGFloat = 200  // Unused
    var lineHeight: CGFloat = 16
    var showExpandButton: Bool = true  // Unused

    private var parsedLines: [ContentLineParser.ParsedLine] {
        ContentLineParser.parse(content)
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
                    ForEach(parsedLines) { line in
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
