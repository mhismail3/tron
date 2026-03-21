import SwiftUI

// MARK: - Tool Code Block

/// Reusable line-numbered code display extracted from ReadToolDetailSheet (contentSection),
/// WriteToolDetailSheet (contentPreviewSection), and BashToolDetailSheet (outputSection).
///
/// Renders a section header with optional copy button, followed by a scrollable code view
/// with line numbers, left accent border, and configurable line transform.
@available(iOS 26.0, *)
struct ToolCodeBlock: View {
    let title: String
    let lines: [(lineNumber: Int, content: String)]
    let accent: Color
    let tint: TintedColors
    var borderColor: Color? = nil
    var copyContent: String? = nil
    var lineTransform: ((String) -> String)? = nil

    /// Additional content to display between the header and the code block (e.g. range text).
    var headerNote: String? = nil

    /// Whether the content wraps (Write tool) or scrolls horizontally (Read tool).
    var wrapsContent: Bool = false

    private var effectiveBorderColor: Color { borderColor ?? accent }

    private var lineNumWidth: CGFloat {
        let maxNum = lines.last?.lineNumber ?? lines.count
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                if let copyContent {
                    ToolCopyButton(content: copyContent, accent: accent)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if let note = headerNote {
                    Text(note)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(tint.subtle)
                        .padding(.bottom, 6)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }

                codeContent
            }
            .padding(14)
            .sectionFill(accent)
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        if wrapsContent {
            wrappedCodeView
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                wrappedCodeView
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(effectiveBorderColor)
                    .frame(width: 3)
            }
        }
    }

    private var wrappedCodeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.lineNumber) { line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(line.lineNumber)")
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted.opacity(0.4))
                        .frame(width: lineNumWidth, alignment: .trailing)
                        .padding(.leading, 4)
                        .padding(.trailing, 8)

                    let displayContent = lineTransform?(line.content) ?? line.content
                    Text(displayContent.isEmpty ? " " : displayContent)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.body)
                        .if(wrapsContent) { $0.fixedSize(horizontal: false, vertical: true) }
                }
                .frame(minHeight: 16)
                .if(!wrapsContent) { $0 } // no extra frame needed for horizontal scroll
            }
        }
        .padding(.vertical, 3)
        .if(wrapsContent) { view in
            view.overlay(alignment: .leading) {
                Rectangle()
                    .fill(effectiveBorderColor)
                    .frame(width: 3)
            }
        }
    }
}
