import UIKit

/// Owns process-lifetime keyboard visibility and transition state.
/// Native layout remains the authoritative owner of keyboard geometry.
@Observable
@MainActor
final class KeyboardObserver {
    static let shared = KeyboardObserver()

    /// Whether the keyboard is currently visible
    private(set) var isKeyboardVisible: Bool = false

    /// Whether the keyboard is currently animating (showing or hiding)
    private(set) var isAnimating: Bool = false

    private var notificationTasks: [Task<Void, Never>] = []

    private init() {
        setupNotifications()
    }

    private func setupNotifications() {
        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
                self?.isKeyboardVisible = true
                self?.isAnimating = true
            }
        })

        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardDidShowNotification) {
                self?.isAnimating = false
            }
        })

        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillHideNotification) {
                self?.isAnimating = true
            }
        })

        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardDidHideNotification) {
                self?.isKeyboardVisible = false
                self?.isAnimating = false
            }
        })
    }
}
