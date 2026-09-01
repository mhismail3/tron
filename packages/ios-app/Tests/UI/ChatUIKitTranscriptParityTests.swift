import Foundation
import Testing
@testable import TronMobile
@preconcurrency import UIKit

struct ChatUIKitTranscriptParityTests {
    @Test("UIKit row preserves ordered attachment facts and resource metadata")
    func rowPreservesAttachmentFacts() throws {
        let resource = ComposerResourceInvocation(source: .skill, name: "review", arguments: "")
        let facts = [
            ChatUIKitTranscriptAttachment(
                id: "photo-1", name: "photo.png", mimeType: "image/png",
                size: 128, blobID: "blob-1"
            ),
            ChatUIKitTranscriptAttachment(
                id: "file-1", name: "notes.md", mimeType: "text/markdown",
                size: 64, blobID: "blob-2"
            )
        ]
        let row = ChatUIKitTranscriptRow(
            id: "prompt-1",
            text: "Review these files",
            kind: .user,
            attachmentFacts: facts,
            resourceInvocation: resource
        )!

        #expect(row.attachmentFacts == facts)
        #expect(row.attachments == ["photo.png", "notes.md"])
        #expect(row.resourceInvocation == resource)
    }

    @Test("UIKit theme keeps code geometry aligned with the native Markdown contract")
    @MainActor
    func codePresentationContract() {
        #expect(ChatUIKitTheme.codeTextInsets == UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        #expect(ChatUIKitTheme.codeLineSpacing == 3)
        #expect(ChatUIKitTheme.elevatedSurface.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) != ChatUIKitTheme.elevatedSurface.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        #expect(!ChatUIKitPulseLoadingView(accent: ChatUIKitTheme.emerald).isAccessibilityElement)
    }

    @Test("UIKit code blocks measure every line while the outer viewport stays horizontal")
    @MainActor
    func multilineCodeLayoutUsesNaturalHeight() throws {
        let source = "```swift\nlet first = 1\nlet second = 2\nlet third = 3\n```"
        let document = MarkdownPresentation.Document(source: source)
        let row = try #require(ChatUIKitTranscriptRow(
            id: "code-row", text: source, markdownDocuments: [document]
        ))
        let view = ChatUIKitMarkdownView()
        view.render(row)
        let fitting = view.systemLayoutSizeFitting(
            CGSize(width: 320, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(x: 0, y: 0, width: 320, height: fitting.height)
        view.layoutIfNeeded()
        let code = try #require(descendantTextView(in: view, text: "let first = 1\nlet second = 2\nlet third = 3"))
        let scroll = try #require(code.superview as? UIScrollView)
        #expect(code.frame.height > (code.font?.lineHeight ?? 0) * 2.5)
        #expect(scroll.alwaysBounceVertical == false)
        #expect(scroll.showsVerticalScrollIndicator == false)
        #expect(scroll.contentSize.height <= scroll.bounds.height + 1)
    }

    @Test("UIKit tables measure multiple rows instead of clipping to one viewport height")
    @MainActor
    func multilineTableLayoutUsesNaturalHeight() throws {
        let source = "| Name | Value |\n| --- | --- |\n| first | one |\n| second | two |\n| third | three |"
        let document = MarkdownPresentation.Document(source: source)
        let row = try #require(ChatUIKitTranscriptRow(
            id: "table-row", text: source, markdownDocuments: [document]
        ))
        let view = ChatUIKitMarkdownView()
        view.render(row)
        let fitting = view.systemLayoutSizeFitting(
            CGSize(width: 320, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(x: 0, y: 0, width: 320, height: fitting.height)
        view.layoutIfNeeded()
        let table = try #require(descendantScrollView(in: view))
        #expect(table.frame.height > 40)
        #expect(table.contentSize.height <= table.bounds.height + 1)
        #expect(table.alwaysBounceVertical == false)
    }

    @Test("UIKit preserves links from MarkdownPresentation attributed runs")
    func markdownLinksRemainRealAttributes() throws {
        let inline = MarkdownPresentation.Inline(source: "Open [the transcript](https://example.com/log)")
        let attributed = try #require(inline.attributedString)
        let links = attributed.runs.compactMap { run -> (NSRange, URL)? in
            guard let url = run.link else { return nil }
            return (NSRange(run.range, in: attributed), url)
        }
        let link = try #require(links.first)
        #expect(link.1.absoluteString == "https://example.com/log")
        #expect((String(attributed.characters) as NSString).substring(with: link.0) == "the transcript")
    }

    @Test("canonical lifecycle kinds expose typed notification facts")
    func canonicalLifecycleFacts() throws {
        let values = [
            ("compaction", "Context compacted"),
            ("branchSummary", "Branch summary"),
            ("modelChange", "Model changed"),
            ("thinkingChange", "Thinking changed"),
            ("label", "Bookmark: checkpoint")
        ]
        for (kind, title) in values {
            let json: String
            switch kind {
            case "compaction": json = #"{"id":"item","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"summary"}"#
            case "branchSummary": json = #"{"id":"item","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"branchSummary","summary":"summary"}"#
            case "modelChange": json = #"{"id":"item","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"modelChange","modelRef":{"provider":"test","id":"model"}}"#
            case "thinkingChange": json = #"{"id":"item","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"thinkingChange","level":"high"}"#
            default: json = #"{"id":"item","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"label","targetId":"item","label":"checkpoint"}"#
            }
            let item = try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data(json.utf8))
            #expect(ChatNotificationPresentation.canonical(item, globalOrdinal: 0)?.title == title)
        }
    }

    @Test("media chips have explicit terminal lifecycle states")
    func mediaLifecycleVocabulary() {
        #expect(ChatMediaLoadState.idle != .loading)
        #expect(ChatMediaLoadState.succeeded != .failed)
        #expect(ChatMediaLoadState.cancelled != .idle)
    }

    @Test("stable media chips replace metadata and VoiceOver projection")
    @MainActor
    func mediaChipReconfigurationRetiresOldAccessibilityFacts() {
        let first = ChatUIKitTranscriptAttachment(
            id: "same", name: "old.txt", mimeType: "text/plain", size: 10
        )
        let replacement = ChatUIKitTranscriptAttachment(
            id: "same", name: "new.png", mimeType: "image/png", size: 20
        )
        let chip = ChatUIKitMediaChip(attachment: first)
        chip.reconfigure(replacement)
        #expect(chip.attachment == replacement)
        #expect(chip.accessibilityLabel == "Image attachment, new.png")
        #expect(chip.accessibilityValue?.contains("old.txt") == false)
        #expect(chip.loadState == .idle)
    }

    @Test("UIKit attachment equality ignores decoded image object identity")
    func attachmentEqualityUsesWireFacts() {
        let first = ChatUIKitTranscriptAttachment(
            id: "image", name: "image.png", mimeType: "image/png", blobID: "blob"
        )
        let second = ChatUIKitTranscriptAttachment(
            id: "image", name: "image.png", mimeType: "image/png", blobID: "blob"
        )
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @MainActor
    private func descendantTextView(in view: UIView, text: String) -> UITextView? {
        if let textView = view as? UITextView, textView.text == text { return textView }
        for child in view.subviews {
            if let match = descendantTextView(in: child, text: text) { return match }
        }
        return nil
    }

    @MainActor
    private func descendantScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.subviews.contains(where: { $0 is UIStackView }) { return scroll }
        for child in view.subviews {
            if let match = descendantScrollView(in: child) { return match }
        }
        return nil
    }
}
