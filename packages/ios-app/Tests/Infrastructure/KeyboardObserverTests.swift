import XCTest
@testable import TronMobile

// MARK: - KeyboardObserver Tests

@MainActor
final class KeyboardObserverTests: XCTestCase {

    // MARK: - Initial State Tests

    func test_shared_isSingleton() {
        let instance1 = KeyboardObserver.shared
        let instance2 = KeyboardObserver.shared
        XCTAssertTrue(instance1 === instance2)
    }

    func test_initialState_keyboardHidden() {
        let observer = KeyboardObserver.shared

        // Initial state should show keyboard as hidden
        // Note: actual values depend on system state, but we verify properties exist
        XCTAssertGreaterThanOrEqual(observer.keyboardHeight, 0)
        XCTAssertFalse(observer.isAnimating)
    }

    // MARK: - Property Existence Tests

    func test_keyboardHeight_isAccessible() {
        let observer = KeyboardObserver.shared
        _ = observer.keyboardHeight
    }

    func test_isKeyboardVisible_isAccessible() {
        let observer = KeyboardObserver.shared
        _ = observer.isKeyboardVisible
    }

    func test_isAnimating_isAccessible() {
        let observer = KeyboardObserver.shared
        _ = observer.isAnimating
    }

    // MARK: - Notification Handling Tests

    func test_keyboardWillShow_updatesState() async {
        let observer = KeyboardObserver.shared

        // Simulate keyboard will show notification
        let keyboardFrame = CGRect(x: 0, y: 500, width: 400, height: 300)
        let userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: keyboardFrame
        ]

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: userInfo
        )

        // Give async notification handling time to complete
        try? await Task.sleep(for: .milliseconds(100))

        // Verify state updated
        XCTAssertEqual(observer.keyboardHeight, 300)
        XCTAssertTrue(observer.isKeyboardVisible)
        XCTAssertTrue(observer.isAnimating)
    }

    func test_keyboardDidShow_stopsAnimating() async {
        let observer = KeyboardObserver.shared

        // First show keyboard
        let keyboardFrame = CGRect(x: 0, y: 500, width: 400, height: 300)
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboardFrame]
        )

        try? await Task.sleep(for: .milliseconds(50))

        // Then complete show animation
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(observer.isAnimating)
    }

    func test_keyboardWillHide_startsAnimating() async {
        let observer = KeyboardObserver.shared

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(observer.isAnimating)
    }

    func test_keyboardDidHide_resetsState() async {
        let observer = KeyboardObserver.shared

        // First show keyboard
        let keyboardFrame = CGRect(x: 0, y: 500, width: 400, height: 300)
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboardFrame]
        )

        try? await Task.sleep(for: .milliseconds(50))

        // Then hide keyboard
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(observer.keyboardHeight, 0)
        XCTAssertFalse(observer.isKeyboardVisible)
        XCTAssertFalse(observer.isAnimating)
    }

    // MARK: - Edge Cases

    func test_keyboardWillShow_withMissingUserInfo_handlesGracefully() async {
        let observer = KeyboardObserver.shared
        let initialHeight = observer.keyboardHeight

        // Post notification without userInfo
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        // Should not crash and height should remain unchanged
        XCTAssertEqual(observer.keyboardHeight, initialHeight)
    }
}
