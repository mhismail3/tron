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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.tronStandard) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    TronIconView(icon: .thinking, size: 12, color: .tronTextMuted)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextMuted)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            if expanded {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .italic()
            }
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
    }
}
