import SwiftUI

// MARK: - Streaming Content View (Terminal-style)

/// Displays streaming text with a visual indicator (green accent line)
/// Optimized for efficient rendering during rapid text updates
struct StreamingContentView: View {
    let text: String
    @Environment(\.textSelectionDisabled) private var textSelectionDisabled

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Green vertical accent line (matching web UI)
            accentLine

            // Dynamic text content
            textContent
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Subviews (extracted for render efficiency)

    /// Static accent line - won't rebuild on text changes
    private var accentLine: some View {
        Rectangle()
            .fill(Color.tronEmerald)
            .frame(width: 2)
            .padding(.trailing, 12)
    }

    /// Dynamic text content
    private var textContent: some View {
        Group {
            if text.isEmpty {
                Text(" ")
                    .font(TronTypography.messageBody)
            } else {
                // Use plain Text, NOT LocalizedStringKey - avoids parsing overhead
                Text(text)
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.assistantMessageText)
                    .lineSpacing(4)
                    .selectableText(!textSelectionDisabled)
            }
        }
    }
}
