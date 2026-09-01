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
    @MainActor
    func equalRevisionAuthoritativeStateIsAdmittedWithoutRollback() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        #expect(controller.apply(ChatUIKitComposerInput(
            revision: 7,
            submissionID: "submission-7",
            isSending: false,
            focus: .focused
        )))
        #expect(controller.apply(ChatUIKitComposerInput(
            revision: 7,
            submissionID: "submission-7",
            isSending: true,
            submissionPending: true,
            focus: .resigned
        )))
        #expect(controller.input?.isSending == true)
        #expect(controller.input?.focus == .resigned)
        #expect(!controller.apply(ChatUIKitComposerInput(revision: 6, focus: .focused)))
    }

    @Test
    @MainActor
    func rejectedSendCanRetryOnlyAfterExplicitResolution() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session",
            text: "send",
            revision: 1,
            submissionID: "submission-1",
            trailingMode: .send,
            isTranscriptReady: true,
            isCommandReady: true
        ))
        var sends = 0
        controller.onIntent = { intent in
            if case .send = intent { sends += 1 }
        }
        let sendButton = controller.view.accessibilityElements?.compactMap { $0 as? UIButton }.last
        sendButton?.sendActions(for: .primaryActionTriggered)
        sendButton?.sendActions(for: .primaryActionTriggered)
        #expect(sends == 1)
        let identity = ChatUIKitComposerSendIdentity(sessionID: "session", submissionID: "submission-1")!
        controller.resolveSend(identity: identity, accepted: false)
        sendButton?.sendActions(for: .primaryActionTriggered)
        #expect(sends == 2)
    }

    @Test
    @MainActor
    func acceptedSendStaysSuppressedAcrossNewerRevisionForSameIdentity() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        let identity = ChatUIKitComposerSendIdentity(sessionID: "session", submissionID: "submission-1")!
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session", text: "send", revision: 1,
            submissionID: "submission-1", trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        var sends = 0
        controller.onIntent = { intent in if case .send = intent { sends += 1 } }
        let button = controller.view.accessibilityElements?.compactMap { $0 as? UIButton }.last
        button?.sendActions(for: .primaryActionTriggered)
        controller.resolveSend(identity: identity, accepted: true)
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session", text: "send", revision: 2,
            submissionID: "submission-1", trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        button?.sendActions(for: .primaryActionTriggered)
        #expect(sends == 1)
    }

    @Test
    @MainActor
    func newIdentityReleasesPriorAcceptedSend() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session", text: "send", revision: 1,
            submissionID: "submission-1", trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        var sends = 0
        controller.onIntent = { intent in if case .send = intent { sends += 1 } }
        let button = controller.view.accessibilityElements?.compactMap { $0 as? UIButton }.last
        button?.sendActions(for: .primaryActionTriggered)
        let first = ChatUIKitComposerSendIdentity(sessionID: "session", submissionID: "submission-1")!
        controller.resolveSend(identity: first, accepted: true)
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session", text: "send", revision: 2,
            submissionID: "submission-2", trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        button?.sendActions(for: .primaryActionTriggered)
        #expect(sends == 2)
    }

    @Test
    @MainActor
    func sendResolutionRequiresExactScopedIdentity() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session",
            text: "send",
            revision: 1,
            submissionID: "submission-1",
            trailingMode: .send,
            isTranscriptReady: true,
            isCommandReady: true
        ))
        var sends = 0
        controller.onIntent = { intent in
            if case .send = intent { sends += 1 }
        }
        let button = controller.view.accessibilityElements?.compactMap { $0 as? UIButton }.last
        button?.sendActions(for: .primaryActionTriggered)
        let wrong = ChatUIKitComposerSendIdentity(sessionID: "session", submissionID: "submission-2")!
        controller.resolveSend(identity: wrong, accepted: false)
        button?.sendActions(for: .primaryActionTriggered)
        #expect(sends == 1)
        let exact = ChatUIKitComposerSendIdentity(sessionID: "session", submissionID: "submission-1")!
        controller.resolveSend(identity: exact, accepted: false)
        button?.sendActions(for: .primaryActionTriggered)
        #expect(sends == 2)
    }

    @Test
    @MainActor
    func noArgumentResourceCanSendWithExactIdentity() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        let resource = ComposerResourceEntry(command: CommandInfo(
            name: "extension-command", description: "Run extension", argumentHint: nil,
            source: .extension, sourcePath: nil, resourceSource: nil,
            resourceScope: nil, resourceOrigin: nil
        ))
        controller.apply(ChatUIKitComposerInput(
            sessionID: "session", revision: 1, submissionID: "resource-1",
            selectedResource: resource, trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        var sends = 0
        controller.onIntent = { intent in if case .send = intent { sends += 1 } }
        controller.view.accessibilityElements?.compactMap { $0 as? UIButton }.last?
            .sendActions(for: .primaryActionTriggered)
        #expect(sends == 1)
    }

    @Test
    @MainActor
    func sendRequiresScopedIdentity() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        controller.apply(ChatUIKitComposerInput(
            text: "send",
            revision: 1,
            trailingMode: .send,
            isTranscriptReady: true,
            isCommandReady: true
        ))
        var sends = 0
        controller.onIntent = { intent in if case .send = intent { sends += 1 } }
        controller.view.accessibilityElements?.compactMap { $0 as? UIButton }.last?
            .sendActions(for: .primaryActionTriggered)
        #expect(sends == 0)
    }

    @Test
    @MainActor
    func authoritativeFocusControlIsApplied() {
        let controller = ChatUIKitComposerController()
        controller.loadViewIfNeeded()
        controller.apply(ChatUIKitComposerInput(
            isEditable: true,
            focus: .focused
        ))
        #expect(controller.input?.focus == .focused)
        controller.apply(ChatUIKitComposerInput(revision: 1, focus: .resigned))
        #expect(controller.input?.focus == .resigned)
        #expect(!controller.apply(ChatUIKitComposerInput(revision: 0, focus: .focused)))
    }

    @Test
    func semanticIntentHasDistinctTerminalActions() {
        let identity = ChatUIKitComposerSendIdentity(sessionID: "session", submissionID: "submission")!
        let send = ChatUIKitComposerIntent.send(behavior: nil, identity: identity)
        let steer = ChatUIKitComposerIntent.send(behavior: "steer", identity: identity)
        #expect(send != steer)
        #expect(ChatUIKitComposerIntent.abort != send)
    }
}
