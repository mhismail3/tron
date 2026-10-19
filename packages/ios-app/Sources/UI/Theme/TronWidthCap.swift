import SwiftUI
import UIKit

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

/// A title's width cap, set by the owner of a compact label (a worker result
/// chip) and applied only where the label's title opts in with
/// `tronTitleWidthCap()`. The base width is for the default text size and
/// scales with Dynamic Type; a narrower proposal still bounds the title.
struct TronTitleWidthCap: Equatable {
    let base: CGFloat
    /// About "Worker · " and three or four title words at the default size.
    static let workerTaskTitle = TronTitleWidthCap(base: 208)
}

private struct TronTitleWidthCapKey: EnvironmentKey {
    static let defaultValue: TronTitleWidthCap? = nil
}

extension EnvironmentValues {
    var tronTitleWidthCap: TronTitleWidthCap? {
        get { self[TronTitleWidthCapKey.self] }
        set { self[TronTitleWidthCapKey.self] = newValue }
    }
}

private struct TronTitleWidthCapModifier: ViewModifier {
    @Environment(\.tronTitleWidthCap) private var cap
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if let cap {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
            TronWidthCap(maximum: UIFontMetrics(forTextStyle: .footnote).scaledValue(for: cap.base, compatibleWith: traits)) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Applies the environment's `tronTitleWidthCap`, if any, to this title.
    func tronTitleWidthCap() -> some View { modifier(TronTitleWidthCapModifier()) }
}
