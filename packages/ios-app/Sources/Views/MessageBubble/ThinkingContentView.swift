import SwiftUI

// MARK: - Thinking Content View

/// Displays thinking content with a vertical line indicator (matching TextContentView exactly)
/// - Only shows spinning brain + "Thinking" label when actively streaming
/// - Historical (non-streaming) blocks show just the text with vertical line
struct ThinkingContentView: View {
    let content: String
    let isExpanded: Bool
    let isStreaming: Bool
    var onTap: (() -> Void)?

    @State private var expanded: Bool

    init(content: String, isExpanded: Bool, isStreaming: Bool = false, onTap: (() -> Void)? = nil) {
        self.content = content
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.onTap = onTap
        self._expanded = State(initialValue: isExpanded)
    }

    /// Preview text (first 2 lines, compact for minimal footprint)
    private var previewText: String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(2)
        let preview = lines.joined(separator: " ")
        if preview.count > 140 {
            return String(preview.prefix(137)) + "..."
        }
        return preview
    }

    /// Whether content exceeds the preview
    private var hasMoreContent: Bool {
        content.count > 140 || content.components(separatedBy: .newlines).count > 2
    }

    var body: some View {
        // Match TextContentView layout exactly
        HStack(alignment: .top, spacing: 0) {
            // Vertical line indicator - matches TextContentView (width: 2, trailing padding: 12)
            // Use muted color for thinking vs green for response
            Rectangle()
                .fill(Color.tronTextMuted.opacity(0.4))
                .frame(width: 2)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 4) {
                // Header with thinking icon - ONLY shown when actively streaming
                if isStreaming {
                    HStack(spacing: 6) {
                        RotatingIcon(icon: .thinking, size: 12, color: Color.secondary.opacity(0.7))
                        Text("Thinking")
                            .font(TronTypography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.secondary.opacity(0.8))
                    }
                }

                // Content: preview or full (compact, smaller text)
                // Use LocalizedStringKey for markdown rendering (bold, italic, etc.)
                Text(LocalizedStringKey(expanded ? content : previewText))
                    .font(TronTypography.mono(size: 10, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .italic()
                    .lineLimit(expanded ? nil : 2)
                    .lineSpacing(1)
                    .animation(.tronStandard, value: expanded)
            }
        }
        // Match TextContentView padding exactly
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            // If there's an onTap handler (for opening sheet), use that
            if let onTap = onTap {
                onTap()
            } else if hasMoreContent {
                // Fallback to inline expansion
                withAnimation(.tronStandard) {
                    expanded.toggle()
                }
            }
        }
    }
}
