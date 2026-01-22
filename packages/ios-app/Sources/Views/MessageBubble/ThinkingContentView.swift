import SwiftUI

// MARK: - Thinking Content View

struct ThinkingContentView: View {
    let content: String
    let isExpanded: Bool

    @State private var expanded: Bool

    init(content: String, isExpanded: Bool) {
        self.content = content
        self.isExpanded = isExpanded
        self._expanded = State(initialValue: isExpanded)
    }

    /// Preview text (first 3 lines, max 120 chars)
    private var previewText: String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
        let preview = lines.joined(separator: " ")
        if preview.count > 120 {
            return String(preview.prefix(117)) + "..."
        }
        return preview
    }

    /// Whether content exceeds the preview
    private var hasMoreContent: Bool {
        content.count > 120 || content.components(separatedBy: .newlines).count > 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with thinking icon
            HStack(spacing: 6) {
                RotatingIcon(icon: .thinking, size: 12, color: Color.secondary.opacity(0.7))
                Text("Thinking")
                    .font(TronTypography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.secondary.opacity(0.8))
                Spacer()
                if hasMoreContent {
                    Button {
                        withAnimation(.tronStandard) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                }
            }

            // Content: preview or full
            Text(expanded ? content : previewText)
                .font(TronTypography.caption)
                .foregroundStyle(Color.secondary.opacity(0.8))
                .italic()
                .lineLimit(expanded ? nil : 3)
                .animation(.tronStandard, value: expanded)
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasMoreContent {
                withAnimation(.tronStandard) {
                    expanded.toggle()
                }
            }
        }
    }
}
