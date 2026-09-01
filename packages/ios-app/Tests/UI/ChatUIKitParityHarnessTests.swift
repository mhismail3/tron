import Foundation
import Testing
@testable import TronMobile
@preconcurrency import UIKit

/// Test-only integration harness. It deliberately feeds both native surfaces
/// from immutable installed-contract projections; no production switch or
/// SwiftUI view is involved.
@MainActor
struct ChatUIKitParityHarnessTests {
    @Test("installed transcript and composer projections mount independently")
    func mountsInstalledContracts() throws {
        let harness = ChatUIKitParityHarness()
        let transcriptRows = [
            ChatUIKitTranscriptRow(id: "user", text: "Review **this**")!,
            ChatUIKitTranscriptRow(id: "assistant", text: "Here is the answer", streaming: true)!,
            ChatUIKitTranscriptRow(id: "thinking", text: "", kind: .thinking, thinkingLabel: "Thinking")!
        ]
        let commit = try #require(ChatUIKitTranscriptCommit(version: 1, rows: transcriptRows))
        #expect(harness.installTranscript(commit) == .applied(1))
        harness.installComposer(ChatUIKitComposerInput(
            sessionID: "session",
            text: "draft",
            revision: 1,
            trailingMode: .send,
            isTranscriptReady: true,
            isCommandReady: true,
            attachmentActionsEnabled: true
        ))

        #expect(harness.transcriptItemCount == transcriptRows.count)
        #expect(harness.composerInput?.text == "draft")
    }

    @Test("native collection view keeps a legal nonblank viewport while streaming grows and shrinks")
    func verifiesViewportFlows() throws {
        let harness = ChatUIKitParityHarness()
        let initialRows = (0..<18).map { index in
            ChatUIKitTranscriptRow(id: "row-\(index)", text: "Message \(index)")!
        }
        #expect(harness.installTranscript(try #require(.init(version: 1, rows: initialRows))) == .applied(1))
        harness.followTail()
        #expect(harness.viewportIsLegalAndNonblank)

        let streamingRows = initialRows.enumerated().map { index, row in
            ChatUIKitTranscriptRow(
                id: row.id,
                text: index == initialRows.count - 1 ? String(repeating: "streaming output ", count: 80) : row.text,
                streaming: index == initialRows.count - 1
            )!
        }
        #expect(harness.installTranscript(try #require(.init(version: 2, rows: streamingRows))) == .applied(2))
        #expect(harness.viewportIsLegalAndNonblank)

        harness.beginNativeDrag()
        let detachedOffset = harness.scrollOffset
        let finalizedRows = streamingRows.enumerated().map { index, row in
            ChatUIKitTranscriptRow(id: row.id, text: index == streamingRows.count - 1 ? "final" : row.text)!
        }
        #expect(harness.installTranscript(try #require(.init(version: 3, rows: finalizedRows))) == .applied(3))
        #expect(harness.scrollOffset == detachedOffset)
        #expect(harness.viewportIsLegalAndNonblank)
        harness.endNativeDrag()
        #expect(harness.viewportIsLegalAndNonblank)
    }
}

@MainActor
private final class ChatUIKitParityHarness {
    let transcript = ChatUIKitChatViewController()
    let composer = ChatUIKitComposerController()
    private let transcriptFrame = CGRect(x: 0, y: 0, width: 390, height: 844)

    init() {
        transcript.loadViewIfNeeded()
        transcript.view.frame = transcriptFrame
        transcript.view.layoutIfNeeded()
        composer.loadViewIfNeeded()
        composer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 150)
        composer.view.layoutIfNeeded()
    }

    var transcriptItemCount: Int {
        collectionView.numberOfItems(inSection: 0)
    }

    var composerInput: ChatUIKitComposerInput? { composer.input }

    @discardableResult
    func installTranscript(_ input: ChatUIKitPresentationInput) -> ChatUIKitViewportTransactionOutcome {
        let result = transcript.apply(input)
        transcript.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        return result
    }

    func installComposer(_ input: ChatUIKitComposerInput) {
        composer.apply(input)
        composer.view.layoutIfNeeded()
    }

    func followTail() {
        transcript.setIntent(.followTail)
        collectionView.layoutIfNeeded()
    }

    func beginNativeDrag() {
        transcript.scrollViewWillBeginDragging(collectionView)
    }

    func endNativeDrag() {
        transcript.scrollViewDidEndDragging(collectionView, willDecelerate: false)
    }

    var scrollOffset: CGFloat { collectionView.contentOffset.y }

    var viewportIsLegalAndNonblank: Bool {
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(minimum, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let offsetIsLegal = collectionView.contentOffset.y >= minimum - 0.5
            && collectionView.contentOffset.y <= maximum + 0.5
        let intersection = collectionView.visibleCells.contains { cell in
            cell.frame.intersects(collectionView.bounds.insetBy(dx: 0, dy: 1))
        }
        return offsetIsLegal && (transcriptItemCount == 0 || intersection)
    }

    private var collectionView: UICollectionView {
        guard let collectionView = descendant(of: transcript.view, matching: UICollectionView.self) else {
            fatalError("UIKit transcript collection view is not mounted")
        }
        return collectionView
    }

    private func descendant<T: UIView>(of view: UIView, matching type: T.Type) -> T? {
        if let value = view as? T { return value }
        for child in view.subviews {
            if let value = descendant(of: child, matching: type) { return value }
        }
        return nil
    }
}
