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
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
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

    @Test("external completion selection clamps in UTF-16 coordinates")
    func completionSelectionClamps() {
        var text = "👋 command"
        var focused = false
        var selection = NSRange(location: 999, length: 3)
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        #expect(coordinator.clampedSelection(selection, text: text) == NSRange(
            location: (text as NSString).length,
            length: 0
        ))
        selection = NSRange(location: 2, length: 4)
        #expect(coordinator.clampedSelection(selection, text: text) == selection)
    }

    @Test("context ring mounts disabled at zero and enables with canonical progress")
    func contextProgressReadiness() {
        let loading = SessionContextProgressPolicy.presentation(
            isTranscriptReady: false,
            contextPercentage: 68,
            modelName: "Model",
            isCompacting: true
        )
        #expect(loading == SessionContextProgressPresentation(
            contextPercentage: 0,
            modelName: nil,
            isCompacting: false,
            isEnabled: false
        ))
        #expect(!SessionContextProgressPolicy.presentation(
            isTranscriptReady: true,
            contextPercentage: nil,
            modelName: nil,
            isCompacting: false
        ).isEnabled)

        let ready = SessionContextProgressPolicy.presentation(
            isTranscriptReady: true,
            contextPercentage: 68,
            modelName: "Model",
            isCompacting: true
        )
        #expect(ready == SessionContextProgressPresentation(
            contextPercentage: 68,
            modelName: "Model",
            isCompacting: true,
            isEnabled: true
        ))
    }

    @Test("active chats dismiss the keyboard after steering")
    func activeChatComposerPolicy() {
        for phase in [SessionPhase.running, .compacting, .retrying] {
            #expect(ChatComposerPolicy.isTextEditable(isTranscriptReady: true))
            #expect(ChatComposerPolicy.trailingMode(
                phase: phase,
                hasContent: true
            ) == .send)
            let behavior = ChatComposerPolicy.submissionBehavior(phase: phase)
            #expect(behavior == "steer")
            #expect(!ChatComposerPolicy.preservesFocus(submissionBehavior: behavior))
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

    @Test("an admitted send retains its progress control after the draft clears")
    func sendingRetainsTrailingControl() {
        #expect(ChatComposerPolicy.trailingMode(
            phase: .idle,
            hasContent: false,
            isSending: true
        ) == .send)
        #expect(ChatComposerPolicy.trailingMode(
            phase: .running,
            hasContent: false,
            isSending: true
        ) == .send)
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

    @Test("pending photo remove control centers a compact target on the preview corner")
    func pendingPhotoRemoveGeometry() {
        #expect(PendingPhotoRemoveLayoutPolicy.previewSide == 64)
        #expect(PendingPhotoRemoveLayoutPolicy.visibleDiameter == 22)
        #expect(PendingPhotoRemoveLayoutPolicy.touchTarget == 30)
        #expect(PendingPhotoRemoveLayoutPolicy.centerOnTopTrailingCornerOffset == CGSize(
            width: 15,
            height: -15
        ))
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

    @Test("intrinsic sizing grows to eight lines and reconciles scrolling after final layout")
    func cappedGrowth() throws {
        var text = ""
        var focused = true
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        let width: CGFloat = 240
        let view = makeTextView(coordinator: coordinator, width: width)

        view.text = "one line"
        coordinator.textViewDidChange(view)
        let oneLineHeight = coordinator.resolvedHeight(of: view, width: width)
        view.frame.size.height = oneLineHeight
        coordinator.textViewDidLayout(view)
        #expect(!view.isScrollEnabled)

        view.text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)
        let cappedHeight = coordinator.resolvedHeight(of: view, width: width)
        view.frame.size.height = cappedHeight
        coordinator.textViewDidLayout(view)

        let lineHeight = try #require(view.font).lineHeight
        #expect(view.isScrollEnabled)
        #expect(cappedHeight > oneLineHeight)
        #expect(abs(cappedHeight - ceil(lineHeight * 8)) < 1)
        #expect(text.hasSuffix("line 12"))

        view.text = (1...8).map { "line \($0)" }.joined(separator: "\n")
        coordinator.textViewDidChange(view)
        view.frame.size.height = coordinator.resolvedHeight(of: view, width: width)
        coordinator.textViewDidLayout(view)
        #expect(!view.isScrollEnabled)
        #expect(abs(view.contentOffset.y) < 0.5)

        view.text = ""
        coordinator.textViewDidChange(view)
        let collapsedHeight = coordinator.resolvedHeight(of: view, width: width)
        view.frame.size.height = collapsedHeight
        coordinator.textViewDidLayout(view)
        #expect(!view.isScrollEnabled)
        #expect(abs(collapsedHeight - oneLineHeight) < 1)
    }

    @Test("overflow keeps the rendered trailing-line caret visible")
    func overflowCaretVisibility() {
        var text = ""
        var focused = true
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        let width: CGFloat = 240
        let view = makeTextView(coordinator: coordinator, width: width)
        view.text = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)
        view.frame.size.height = coordinator.resolvedHeight(of: view, width: width)
        coordinator.textViewDidLayout(view)

        #expect(view.isScrollEnabled)
        #expect(view.contentOffset.y > 0)
        #expect(coordinator.hostedCaretIsVisible(in: view))
    }

    @Test("typing after manual internal scrolling moves only toward the caret")
    func manualScrollThenType() {
        var text = ""
        var focused = true
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        let width: CGFloat = 240
        let view = makeTextView(coordinator: coordinator, width: width)
        view.text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)
        view.frame.size.height = coordinator.resolvedHeight(of: view, width: width)
        coordinator.textViewDidLayout(view)

        let manualOffset = max(0, view.contentOffset.y - 12)
        view.setContentOffset(CGPoint(x: 0, y: manualOffset), animated: false)
        view.text += " more"
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)
        coordinator.textViewDidLayout(view)

        #expect(view.contentOffset.y >= manualOffset - 0.5)
        #expect(coordinator.hostedCaretIsVisible(in: view))
    }

    @Test("layout callback reconciles overflow without recursive ownership")
    func layoutCallbackReconcilesOverflow() {
        var text = ""
        var focused = true
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        let width: CGFloat = 240
        let view = makeTextView(coordinator: coordinator, width: width)
        view.text = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)
        view.frame.size.height = coordinator.resolvedHeight(of: view, width: width)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(view.isScrollEnabled)
        #expect(coordinator.hostedCaretIsVisible(in: view))
    }

    @Test("composer measurement is side-effect free and owns no safe-area inset")
    func measurementPurity() {
        var text = ""
        var focused = true
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            isEditable: true,
            keyboardAppearance: .dark
        )
        let coordinator = control.makeCoordinator()
        let view = makeTextView(coordinator: coordinator, width: 240)
        view.text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        view.setContentOffset(CGPoint(x: 0, y: 17), animated: false)
        let scrolling = view.isScrollEnabled
        let offset = view.contentOffset

        let first = coordinator.resolvedHeight(of: view, width: 240)
        let second = coordinator.resolvedHeight(of: view, width: 240)
        #expect(first == second)
        #expect(view.isScrollEnabled == scrolling)
        #expect(view.contentOffset == offset)
        #expect(view.contentInsetAdjustmentBehavior == .never)
        #expect(view.adjustedContentInset == .zero)
    }

    private func makeTextView(
        coordinator: MultilineComposerTextView.Coordinator,
        width: CGFloat
    ) -> MultilineComposerTextView.LayoutAwareTextView {
        let view = MultilineComposerTextView.LayoutAwareTextView(
            frame: CGRect(x: 0, y: 0, width: width, height: 20)
        )
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.contentInsetAdjustmentBehavior = .never
        view.isScrollEnabled = false
        view.didLayout = { [weak coordinator] view in
            coordinator?.textViewDidLayout(view)
        }
        coordinator.updateFont(on: view)
        return view
    }
}
