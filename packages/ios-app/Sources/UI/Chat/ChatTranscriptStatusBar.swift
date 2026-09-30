import OSLog
import SwiftUI
import UIKit

/// Origin-only status-bar routing. The probe is content-owned so ancestry finds
/// exactly this transcript; the window proxy never replaces SwiftUI's delegate.
struct ChatTranscriptStatusBar: UIViewRepresentable {
    let active: Bool
    let scrollToOldest: () -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.active = active
        view.scrollToOldest = scrollToOldest
        view.reconcile()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView, UIScrollViewDelegate {
        var active = false
        var scrollToOldest: (() -> Void)?
        private weak var transcript: UIScrollView?
        private var previousScrollsToTop = true
        private var proxy: UIScrollView?
        private var reportedMissingAncestor = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reconcile()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            reconcile()
        }

        func reconcile() {
            guard active, let window else { detach(); return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else {
                detach()
                if !reportedMissingAncestor {
                    reportedMissingAncestor = true
                    Logger(subsystem: "com.tron.mobile", category: "ChatTranscriptOrientation")
                        .error("Status-bar oldest-history routing unavailable: no enclosing scroll view")
                }
                return
            }
            if transcript === scroll, proxy?.window === window { return }
            detach()
            transcript = scroll
            previousScrollsToTop = scroll.scrollsToTop
            let proxy = UIScrollView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            proxy.backgroundColor = .clear
            proxy.isUserInteractionEnabled = false
            proxy.isAccessibilityElement = false
            proxy.accessibilityElementsHidden = true
            proxy.showsVerticalScrollIndicator = false
            proxy.showsHorizontalScrollIndicator = false
            proxy.contentInsetAdjustmentBehavior = .never
            proxy.contentSize = CGSize(width: 1, height: 2)
            proxy.contentOffset = CGPoint(x: 0, y: 1)
            proxy.delegate = self
            proxy.scrollsToTop = true
            window.addSubview(proxy)
            self.proxy = proxy
            scroll.scrollsToTop = false
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            guard active, scrollView === proxy, window != nil, transcript?.window === window else { return false }
            scrollToOldest?()
            // Keep the proxy off its origin so the next system tap is delivered.
            return false
        }

        func detach() {
            proxy?.delegate = nil
            proxy?.removeFromSuperview()
            proxy = nil
            if let transcript, !transcript.scrollsToTop { transcript.scrollsToTop = previousScrollsToTop }
            transcript = nil
        }
    }
}
