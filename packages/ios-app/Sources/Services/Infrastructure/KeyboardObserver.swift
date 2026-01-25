import Combine
import UIKit

/// Observes keyboard show/hide events and provides keyboard height.
/// Used to ensure UI elements (like Menus) have correct positioning after keyboard dismissal.
@MainActor
final class KeyboardObserver: ObservableObject {
    static let shared = KeyboardObserver()

    /// Current keyboard height (0 when hidden)
    @Published private(set) var keyboardHeight: CGFloat = 0

    /// Whether the keyboard is currently visible
    @Published private(set) var isKeyboardVisible: Bool = false

    /// Whether the keyboard is currently animating (showing or hiding)
    @Published private(set) var isAnimating: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleKeyboardWillShow(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isAnimating = false
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isAnimating = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.keyboardHeight = 0
                self?.isKeyboardVisible = false
                self?.isAnimating = false
            }
            .store(in: &cancellables)
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
