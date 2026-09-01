import Foundation
import Testing
@testable import TronMobile
@preconcurrency import UIKit

struct ChatUIKitComposerTests {
    @Test
    @MainActor
    func layoutPolicyCapsRegularAndKeyboardEditor() {
        let regular = ChatUIKitComposerLayoutPolicy.editorHeight(
            fittingHeight: 10_000,
            lineHeight: 20,
            panelPresented: false,
            keyboardVisible: false
        )
        let keyboard = ChatUIKitComposerLayoutPolicy.editorHeight(
            fittingHeight: 10_000,
            lineHeight: 20,
            panelPresented: true,
            keyboardVisible: true
        )

        #expect(regular == 160)
        #expect(keyboard <= regular)
        #expect(
            ChatUIKitComposerLayoutPolicy.editorHeight(
                fittingHeight: .nan,
                lineHeight: 20,
                panelPresented: false,
                keyboardVisible: false
            ) == ChatUIKitComposerLayoutPolicy.minimumEditorHeight
        )
    }

    @Test
    @MainActor
    func controllerPublishesImmutableProjectionAndAccessibilityOrder() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        let input = ChatUIKitComposerInput(
            sessionID: "session",
            text: "hello",
            selection: NSRange(location: 5, length: 0),
            revision: 4,
            trailingMode: .send,
            offersQueueChoices: true,
            isTranscriptReady: true,
            isCommandReady: true,
            attachmentActionsEnabled: true
        )

        controller.apply(input)

        #expect(controller.input?.text == "hello")
        #expect(controller.input?.revision == 4)
        #expect(controller.view.accessibilityElements?.isEmpty == false)
        #expect(controller.view.accessibilityElements?.count == 4)
    }

    @Test
    func semanticIntentHasDistinctTerminalActions() {
        let send = ChatUIKitComposerIntent.send(behavior: nil)
        let steer = ChatUIKitComposerIntent.send(behavior: "steer")
        #expect(send != steer)
        #expect(ChatUIKitComposerIntent.abort != send)
    }
}
