import SwiftUI

/// Tiny leading badge that labels a chip's *kind* so visually similar
/// chips (e.g., a running backgrounded-Bash vs a running subagent) are
/// distinguishable at a glance without the user having to read the
/// chip title.
///
/// Kept deliberately narrow — 3-5 characters, uppercase, tinted by the
/// chip's status color at a reduced opacity so it doesn't compete with
/// the chip's own label.
struct ToolKindBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(TronTypography.codeSM)
            .foregroundStyle(color.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule(style: .continuous)
                    .fill(color.opacity(0.18))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
                    )
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Tool Kind Badges") {
    VStack(spacing: 8) {
        ToolKindBadge(text: "BG", color: .tronAmber)
        ToolKindBadge(text: "SUB", color: .tronEmerald)
        ToolKindBadge(text: "WAIT", color: .tronAmber)
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
