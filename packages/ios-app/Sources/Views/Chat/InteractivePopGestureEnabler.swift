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
