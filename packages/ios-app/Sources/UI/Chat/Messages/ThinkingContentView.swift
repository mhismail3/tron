import SwiftUI

/// Provider-neutral presentation for reasoning-like text.
///
/// Providers may wrap summary headings in whole-line Markdown emphasis. Those
/// markers describe transport formatting, not user-authored emphasis, so Tron
/// removes only the outer decoration and otherwise preserves the provider's
/// text and paragraph boundaries verbatim.
enum ThinkingTextPresentation {
    static func displayText(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map(stripWholeLineDecoration)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func previewText(_ content: String, characterLimit: Int = 140) -> String {
        let lines = displayText(content)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(2)
        return lines.joined(separator: "\n").truncated(to: characterLimit)
    }

    private static func stripWholeLineDecoration(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        var value = line.trimmingCharacters(in: .whitespaces)

        for delimiter in ["**", "__"] where value.count > delimiter.count * 2
            && value.hasPrefix(delimiter)
            && value.hasSuffix(delimiter) {
            value = String(value.dropFirst(delimiter.count).dropLast(delimiter.count))
            break
        }

        if let firstContent = value.firstIndex(where: { $0 != "#" }),
           firstContent != value.startIndex,
           value[firstContent] == " " {
            value = String(value[value.index(after: firstContent)...])
        }

        return String(leading) + value
    }
}

// MARK: - Thinking Content View

/// - Only shows pulsing sparkle + "Thinking" label when actively streaming
/// - Persisted non-streaming blocks show the same compact text presentation
struct ThinkingContentView: View {
    let content: String
    let isExpanded: Bool
    let isStreaming: Bool
    let kind: ThinkingDisplayKind
    var onTap: (() -> Void)?

    @State private var expanded: Bool

    init(
        content: String,
        isExpanded: Bool,
        isStreaming: Bool = false,
        kind: ThinkingDisplayKind = .thinking,
        onTap: (() -> Void)? = nil
    ) {
        self.content = content
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.kind = kind
        self.onTap = onTap
        self._expanded = State(initialValue: isExpanded)
    }

    /// Preview text (first 2 lines, compact for minimal footprint)
    private var previewText: String {
        ThinkingTextPresentation.previewText(content)
    }

    /// Whether content exceeds the preview
    private var hasMoreContent: Bool {
        content.count > 140 || content.components(separatedBy: .newlines).count > 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with source contract - shown while streaming and for
            // reasoning summaries whose text is not raw append-only thinking.
            if isStreaming || kind == .reasoningSummary {
                HStack(spacing: 6) {
                    if isStreaming {
                        PulsingIcon(icon: .thinking, size: 12, color: Color.secondary.opacity(0.7))
                    } else {
                        TronIconView(icon: .thinking, size: 12, color: Color.secondary.opacity(0.7))
                    }
                    Text(kind.title)
                        .font(TronTypography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.secondary.opacity(0.8))
                }
            }

            // Reasoning is provider telemetry, not assistant-authored Markdown.
            // Render it as stable regular-weight text across every provider.
            Text(expanded ? ThinkingTextPresentation.displayText(content) : previewText)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .italic()
                .lineLimit(expanded ? nil : 2)
                .lineSpacing(1)
                .animation(.tronStandard, value: expanded)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            // If there's an onTap handler (for opening sheet), use that
            if let onTap = onTap {
                onTap()
            } else if hasMoreContent {
                // Inline expansion is used when no parent sheet action is supplied.
                withAnimation(.tronStandard) {
                    expanded.toggle()
                }
            }
        }
    }
}
