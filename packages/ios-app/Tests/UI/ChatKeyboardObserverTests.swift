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

    @Test("responder publishes a window attachment after the initial render")
    func responderWindowAttachmentIsObservable() {
        let responder = ChatComposerResponder()
        let textView = UITextView()
        responder.attach(textView)
        #expect(responder.window == nil)
        let initialRevision = responder.windowRevision
        let window = UIWindow()
        responder.updateWindow(window)
        #expect(responder.window === window)
        #expect(responder.windowRevision == initialRevision + 1)
        responder.detach(textView)
        #expect(responder.window == nil)
        #expect(responder.windowRevision == initialRevision + 2)
    }

    @Test("notifications are ignored until an attached owner window exists")
    func requiresOwnerWindow() throws {
        let center = NotificationCenter()
        let observer = ChatKeyboardObserver()
        observer.start(center: center)
        defer { observer.stop(center: center) }
        center.post(
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
            userInfo: [UIResponder.keyboardAnimationDurationUserInfoKey: 0.2]
        )
        #expect(observer.revision == 0)
        #expect(observer.transition == nil)
    }
}
