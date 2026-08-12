import SwiftUI
import UIKit

/// Restores the native left-edge back gesture when ChatView hides the system
/// back button in favor of Tron's emerald toolbar control.
struct InteractivePopGestureEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> PopGestureView {
        PopGestureView()
    }

    func updateUIView(_ uiView: PopGestureView, context: Context) {
        uiView.configureNavigationController()
    }

    final class PopGestureView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureNavigationController()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            configureNavigationController()
        }

        func configureNavigationController() {
            guard let navigationController = findNavigationController() else { return }
            navigationController.navigationBar.topItem?.hidesBackButton = true
            navigationController.topViewController?.navigationItem.hidesBackButton = true
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
            navigationController.interactivePopGestureRecognizer?.delegate = nil
        }

        private func findNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let navigationController = next as? UINavigationController {
                    return navigationController
                }
                responder = next
            }
            return nil
        }
    }
}
