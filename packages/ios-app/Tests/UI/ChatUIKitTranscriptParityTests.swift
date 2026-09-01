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
