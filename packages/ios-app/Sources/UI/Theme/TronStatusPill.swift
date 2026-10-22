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

/// Centers its second subview (a pill) on one line of its first, hidden subview
/// (a line of the title's font), and reports that line's baseline as its own, so
/// a first-baseline stack puts the pill on the title line's center.
struct TronTitleLineCenteredLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let line = subviews[0].sizeThatFits(.unspecified), pill = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: pill.width, height: max(line.height, pill.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard subviews.count == 2, guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let line = subviews[0].dimensions(in: .unspecified)
        return bounds.midY - line.height / 2 + line[guide]
    }
}
