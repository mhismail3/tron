import SwiftUI
import UIKit

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

struct TronTitleWidthCap: Equatable {
    let base: CGFloat
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
    func tronTitleWidthCap() -> some View { modifier(TronTitleWidthCapModifier()) }
}
