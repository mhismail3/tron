import SwiftUI

/// Offers its content at most `maximum` points and takes the content's own
/// size, unlike a flexible `frame(maxWidth:)`, which would widen short content
/// to the cap. Text inside truncates by its own truncation mode; the text
/// itself is never shortened.
struct TronWidthCap: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maximum, maximum), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
