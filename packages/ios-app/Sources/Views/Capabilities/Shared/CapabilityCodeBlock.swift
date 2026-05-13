import SwiftUI

// MARK: - Capability Code Block

/// Reusable line-numbered code display shared by source and capability views.
///
/// Renders a section header with optional copy button, followed by a scrollable code view
/// with line numbers and configurable line transform.
@available(iOS 26.0, *)
struct CapabilityCodeBlock: View {
    let title: String
    let lines: [(lineNumber: Int, content: String)]
    let accent: Color
    let tint: TintedColors
    var copyContent: String? = nil
    var lineTransform: ((String) -> String)? = nil

    /// Additional content to display between the header and the code block (e.g. range text).
    var headerNote: String? = nil

    /// Whether the content wraps (Write capability) or scrolls horizontally (Read capability).
    var wrapsContent: Bool = false

    private var lineNumWidth: CGFloat {
        let maxNum = lines.last?.lineNumber ?? lines.count
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 14))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                if let copyContent {
                    CapabilityCopyButton(content: copyContent, accent: accent)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if let note = headerNote {
                    Text(note)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(tint.subtle)
                        .padding(.bottom, 6)
                }

                codeContent
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(accent, compact: lines.count < 100)
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
        }
    }

    private var wrappedCodeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.lineNumber) { line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(line.lineNumber)")
                        .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.tronTextMuted.opacity(0.4))
                        .frame(width: lineNumWidth, alignment: .trailing)
                        .padding(.trailing, 8)

                    let displayContent = lineTransform?(line.content) ?? line.content
                    Text(displayContent.isEmpty ? " " : displayContent)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .if(wrapsContent) { $0.fixedSize(horizontal: false, vertical: true) }
                }
                .frame(minHeight: 16)
                .if(!wrapsContent) { $0 } // no extra frame needed for horizontal scroll
            }
        }
        .padding(.vertical, 3)
    }
}
