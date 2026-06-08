import SwiftUI
import UIKit

// MARK: - Interactive Pop Gesture Enabler

/// Enables the native iOS interactive pop gesture even when the back button is hidden.
/// Add this as a background to any view that hides the navigation back button.
///
/// Uses a UIView-based approach to hide the default back button at the earliest
/// possible moment during a navigation push. UIView.didMoveToWindow fires before
/// any UIViewController lifecycle methods, and the responder chain reaches the
/// UINavigationController even when the VC parent chain isn't fully connected yet.
struct InteractivePopGestureEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> BackButtonSuppressionView {
        BackButtonSuppressionView()
    }

    func updateUIView(_ uiView: BackButtonSuppressionView, context: Context) {
        uiView.hideBackButton()
    }

    final class BackButtonSuppressionView: UIView {
        private var popGestureEnabled = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                hideBackButton()
                popGestureEnabled = false
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hideBackButton()
            enablePopGestureIfNeeded()
        }

        func hideBackButton() {
            guard let nav = findNavigationController() else { return }
            nav.navigationBar.topItem?.hidesBackButton = true
            nav.topViewController?.navigationItem.hidesBackButton = true
        }

        private func enablePopGestureIfNeeded() {
            guard !popGestureEnabled, let nav = findNavigationController() else { return }
            guard nav.topViewController?.viewIfLoaded?.window != nil else { return }
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = nil
            popGestureEnabled = true
        }

        private func findNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let nav = next as? UINavigationController { return nav }
                responder = next
            }
            return nil
        }
    }
}

// MARK: - Navigation Lifecycle Observer

/// Observes UIKit `viewWillDisappear` to fire a callback before the navigation
/// pop animation starts. Used to disable .textSelection(.enabled) before SwiftUI's
/// SDF text renderer is torn down, preventing EXC_BREAKPOINT in
/// SDFStyle.distanceRange.getter.
struct NavigationWillDisappearObserver: UIViewControllerRepresentable {
    let onWillDisappear: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        WillDisappearController(onWillDisappear: onWillDisappear)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private class WillDisappearController: UIViewController {
        let onWillDisappear: () -> Void

        init(onWillDisappear: @escaping () -> Void) {
            self.onWillDisappear = onWillDisappear
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Only fire when being popped (isMovingFromParent), not when a sheet is presented
            if isMovingFromParent {
                onWillDisappear()
            }
        }
    }
}
