import Foundation
import Testing
@testable import TronMobile

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
}
