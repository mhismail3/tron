import SwiftUI

/// A compact state label for a header or row: Home's state, a chapter's state,
/// a task's lifecycle. The pill's text is its whole label.
struct TronStatusPill: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.16)))
            .accessibilityLabel(text)
    }
}
