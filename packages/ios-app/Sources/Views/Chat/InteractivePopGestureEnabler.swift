import SwiftUI
import UIKit

// MARK: - Interactive Pop Gesture Enabler

/// Enables the native iOS interactive pop gesture even when the back button is hidden.
/// Add this as a background to any view that hides the navigation back button.
struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        InteractivePopGestureController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private class InteractivePopGestureController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Re-enable the interactive pop gesture
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
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
