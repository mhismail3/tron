import SwiftUI

// MARK: - Streaming Content View (Terminal-style)

/// Displays streaming text with a visual indicator (green accent line and blinking cursor)
/// Optimized for efficient rendering during rapid text updates
struct StreamingContentView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Green vertical accent line (matching web UI)
            accentLine

            // Dynamic text content with cursor
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

    /// Dynamic text content with blinking cursor
    private var textContent: some View {
        HStack(alignment: .top, spacing: 0) {
            if text.isEmpty {
                Text(" ")
                    .font(TronTypography.messageBody)
            } else {
                // Use plain Text, NOT LocalizedStringKey - avoids parsing overhead
                Text(text)
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.tronTextPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }

            // Blinking cursor indicator
            BlinkingCursor()
        }
    }
}

// MARK: - Blinking Cursor

/// A blinking block cursor for streaming text indicator
/// Separated into its own view so text changes don't affect cursor animation
private struct BlinkingCursor: View {
    @State private var isVisible = true

    var body: some View {
        Text("▋")
            .font(TronTypography.messageBody)
            .foregroundStyle(.tronEmerald)
            .opacity(isVisible ? 0.7 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isVisible)
            .onAppear {
                isVisible = true
            }
    }
}
