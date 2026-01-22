import SwiftUI

// MARK: - Thinking Content View

/// Displays thinking content with a vertical line indicator (like assistant messages)
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

    /// Preview text (first 3 lines, generous character limit for mobile width)
    private var previewText: String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
        let preview = lines.joined(separator: " ")
        // Increase limit to better use available space (mobile screens are ~40-50 chars wide)
        if preview.count > 200 {
            return String(preview.prefix(197)) + "..."
        }
        return preview
    }

    /// Whether content exceeds the preview
    private var hasMoreContent: Bool {
        content.count > 200 || content.components(separatedBy: .newlines).count > 3
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Vertical line indicator (like assistant messages)
            Rectangle()
                .fill(Color.tronTextMuted.opacity(0.4))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))

            VStack(alignment: .leading, spacing: 6) {
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

                // Content: preview or full
                Text(expanded ? content : previewText)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .italic()
                    .lineLimit(expanded ? nil : 3)
                    .animation(.tronStandard, value: expanded)

                // Tap hint for non-expanded content with more to show
                if hasMoreContent && !expanded {
                    Text("Tap to expand")
                        .font(TronTypography.sans(size: 10, weight: .medium))
                        .foregroundStyle(Color.tronPurple.opacity(0.7))
                }
            }
        }
        .padding(.vertical, 4)
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
