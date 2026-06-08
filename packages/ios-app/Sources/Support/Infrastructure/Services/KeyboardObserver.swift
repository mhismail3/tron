import UIKit

/// Observes keyboard show/hide events and provides keyboard height.
/// Used to ensure UI elements (like Menus) have correct positioning after keyboard dismissal.
@Observable
@MainActor
final class KeyboardObserver {
    static let shared = KeyboardObserver()

    /// Current keyboard height (0 when hidden)
    private(set) var keyboardHeight: CGFloat = 0

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
            for await notification in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
                self?.handleKeyboardWillShow(notification)
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
                self?.keyboardHeight = 0
                self?.isKeyboardVisible = false
                self?.isAnimating = false
            }
        })
    }

    private func handleKeyboardWillShow(_ notification: Notification) {
        isAnimating = true

        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        keyboardHeight = keyboardFrame.height
        isKeyboardVisible = true
    }
}
