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
            isEditable: true
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

    @Test("grows to eight lines then gives scrolling to the text view")
    func cappedGrowth() async throws {
        var text = ""
        var focused = true
        var height: CGFloat = 20
        let control = MultilineComposerTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            height: Binding(get: { height }, set: { height = $0 }),
            isEditable: true
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
