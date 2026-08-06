import UIKit

/// Applies Tron's soft edge treatment to UIKit-owned scroll views embedded in
/// SwiftUI presentation roots. SwiftUI's environment style does not reliably
/// cross representable/controller boundaries on iOS 27.
@MainActor
enum TronScrollEdgeEffects {
    static func applySoft(to scrollView: UIScrollView) {
        scrollView.topEdgeEffect.style = .soft
        scrollView.leftEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.style = .soft
        scrollView.rightEdgeEffect.style = .soft
    }

    static func applySoftToDescendantScrollViews(of rootView: UIView) {
        if let scrollView = rootView as? UIScrollView {
            applySoft(to: scrollView)
        }
        for subview in rootView.subviews {
            applySoftToDescendantScrollViews(of: subview)
        }
    }
}
