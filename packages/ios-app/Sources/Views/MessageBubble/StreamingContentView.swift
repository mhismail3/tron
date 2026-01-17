import SwiftUI

// MARK: - Streaming Content View (Terminal-style)

struct StreamingContentView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Green vertical accent line (matching web UI)
            Rectangle()
                .fill(Color.tronEmerald)
                .frame(width: 2)
                .padding(.trailing, 12)

            if text.isEmpty {
                Text(" ")
                    .font(.system(size: 14, design: .monospaced))
            } else {
                Text(LocalizedStringKey(text))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.tronTextPrimary)
                    .lineSpacing(4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
