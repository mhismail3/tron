import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Multiline composer text view")
struct MultilineComposerTextViewTests {
    @Test("a UIKit tap is never resigned by stale mirrored SwiftUI focus")
    func tapFocusSurvivesStaleRender() {
        var text = ""
        var focused = false
        var height: CGFloat = 20
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            height: Binding(get: { height }, set: { height = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        #expect(!MultilineComposerTextView.Coordinator.shouldResign(
            desiredFocus: false,
            isFirstResponder: true,
            hasMirroredFocus: false
        ))

        let view = UITextView()
        coordinator.textViewDidBeginEditing(view)
        #expect(focused)
        #expect(coordinator.hasMirroredFocus)
        #expect(!MultilineComposerTextView.Coordinator.shouldResign(
            desiredFocus: true,
            isFirstResponder: true,
            hasMirroredFocus: true
        ))
    }

    @Test("active chats keep text entry available for steering")
    func activeChatComposerPolicy() {
        for phase in [SessionPhase.running, .compacting, .retrying] {
            #expect(ChatComposerPolicy.isTextEditable(isTranscriptReady: true))
            #expect(ChatComposerPolicy.trailingMode(
                phase: phase,
                hasContent: true
            ) == .send)
            let behavior = ChatComposerPolicy.submissionBehavior(phase: phase)
            #expect(behavior == "steer")
            #expect(ChatComposerPolicy.preservesFocus(submissionBehavior: behavior))
        }
    }

    @Test("failed steering restores the outgoing message without overwriting new input")
    func failedSteeringRestoresDraft() {
        #expect(ChatComposerPolicy.restoredDraft(
            outgoing: "first steering message",
            currentDraft: "second draft"
        ) == "first steering message\nsecond draft")
        #expect(ChatComposerPolicy.restoredDraft(
            outgoing: "first steering message",
            currentDraft: ""
        ) == "first steering message")
        #expect(ChatComposerPolicy.restoredDraft(
            outgoing: "",
            currentDraft: "attachment follow-up"
        ) == "attachment follow-up")
    }

    @Test("an empty active composer keeps the stop action")
    func emptyActiveComposerStopsAgent() {
        #expect(ChatComposerPolicy.trailingMode(
            phase: .running,
            hasContent: false
        ) == .stopAgent)
    }

    @Test("an empty idle composer has no trailing action")
    func emptyIdleComposerHasNoTrailingAction() {
        #expect(ChatComposerPolicy.trailingMode(
            phase: .idle,
            hasContent: false
        ) == nil)
    }

    @Test("idle messages remain ordinary prompts")
    func idleComposerPolicy() {
        #expect(ChatComposerPolicy.trailingMode(
            phase: .idle,
            hasContent: true
        ) == .send)
        let behavior = ChatComposerPolicy.submissionBehavior(phase: .idle)
        #expect(behavior == nil)
        #expect(!ChatComposerPolicy.preservesFocus(submissionBehavior: behavior))
        #expect(ChatComposerPolicy.isTextEditable(isTranscriptReady: false))
    }

    @Test("attachment pickers preserve characterized selection ceilings")
    func attachmentSelectionCeilings() {
        #expect(ChatAttachmentImportPolicy.maximumPhotoSelection == 5)
        #expect(ChatAttachmentImportPolicy.maximumFileSelection == 10)
    }

    @Test("editor confirmation policy preserves wording and empty-draft admission")
    func editorConfirmationPolicy() {
        #expect(ComposerEditorRequestPolicy.confirmationTitle == "Replace the current draft?")
        #expect(ComposerEditorRequestPolicy.useActionTitle == "Use Extension Text")
        #expect(ComposerEditorRequestPolicy.keepActionTitle == "Keep Current Draft")
        #expect(ComposerEditorRequestPolicy.confirmationMessage == "An extension requested a composer change. Tron will not overwrite what you typed without confirmation.")
        #expect(ComposerEditorRequestPolicy.appliesAutomatically(to: ""))
        #expect(!ComposerEditorRequestPolicy.appliesAutomatically(to: "existing"))
    }

    @Test("grows to eight lines then gives scrolling to the text view")
    func cappedGrowth() async throws {
        var text = ""
        var focused = true
        var height: CGFloat = 20
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            height: Binding(get: { height }, set: { height = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 240, height: 20))
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        coordinator.updateFont(on: view)

        view.text = "one line"
        coordinator.textViewDidChange(view)
        try await Task.sleep(for: .milliseconds(20))
        let oneLineHeight = height
        #expect(!view.isScrollEnabled)

        view.text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)
        try await Task.sleep(for: .milliseconds(20))

        let lineHeight = try #require(view.font).lineHeight
        #expect(view.isScrollEnabled)
        #expect(height > oneLineHeight)
        #expect(abs(height - ceil(lineHeight * 8)) < 1)
        #expect(text.hasSuffix("line 12"))
    }
}
