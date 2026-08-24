import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Chat keyboard observer")
struct ChatKeyboardObserverTests {
    @Test("keyboard height is the owner-window intersection")
    func ownerWindowGeometry() {
        #expect(ChatKeyboardObserver.targetHeight(
            localFrame: CGRect(x: 0, y: 500, width: 400, height: 320),
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            isHide: false
        ) == 300)
        #expect(ChatKeyboardObserver.targetHeight(
            localFrame: CGRect(x: 500, y: 500, width: 200, height: 200),
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            isHide: false
        ) == 0)
    }

    @Test("hide notification synchronously clears the target height")
    func synchronousHide() throws {
        let center = NotificationCenter()
        let observer = ChatKeyboardObserver()
        observer.start(center: center)
        defer { observer.stop(center: center) }
        let revision = observer.revision
        center.post(
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
            userInfo: [UIResponder.keyboardAnimationDurationUserInfoKey: 0.2]
        )
        #expect(observer.revision == 1)
        #expect(observer.transitionArrived(after: revision))
        #expect(try #require(observer.transition).targetHeight == 0)
    }
}
