import XCTest
@testable import TronMobile

// MARK: - KeyboardObserver Tests

@MainActor
final class KeyboardObserverTests: XCTestCase {

    func test_shared_isSingleton() {
        let instance1 = KeyboardObserver.shared
        let instance2 = KeyboardObserver.shared
        XCTAssertTrue(instance1 === instance2)
    }

    func test_keyboardWillShow_updatesState() async {
        let observer = KeyboardObserver.shared

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(observer.isKeyboardVisible)
        XCTAssertTrue(observer.isAnimating)
    }

    func test_keyboardDidShow_stopsAnimating() async {
        let observer = KeyboardObserver.shared

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(observer.isKeyboardVisible)
        XCTAssertFalse(observer.isAnimating)
    }

    func test_keyboardWillHide_startsAnimating() async {
        let observer = KeyboardObserver.shared

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(observer.isKeyboardVisible)
        XCTAssertTrue(observer.isAnimating)
    }

    func test_keyboardDidHide_resetsState() async {
        let observer = KeyboardObserver.shared

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(observer.isKeyboardVisible)
        XCTAssertFalse(observer.isAnimating)
    }
}
