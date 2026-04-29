import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class InputBarContentAreaChipTests: XCTestCase {
    private func makeSkill(name: String) -> Skill {
        Skill(
            name: name,
            displayName: name,
            description: "test skill",
            source: .global,
            tags: nil
        )
    }

    private func makeAttachment(
        id: UUID = UUID(),
        type: AttachmentType = .document,
        dataSize: Int = 19,
        mimeType: String = "text/plain",
        fileName: String = "test.txt"
    ) -> Attachment {
        Attachment(
            id: id,
            type: type,
            data: Data(repeating: 0, count: dataSize),
            mimeType: mimeType,
            fileName: fileName
        )
    }

    private var pdfLimitedCapability: AttachmentCapability {
        AttachmentCapability(
            supportsImages: true,
            supportsPdfContent: false,
            supportsTextFiles: true,
            maxImageBytes: 5_242_880,
            maxDocumentBytes: 20_971_520
        )
    }

    private func render(_ view: AttachmentBubble) {
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    private func measuredWidth(_ view: AttachmentBubble) -> CGFloat {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 1_000, height: 1_000)).width
    }

    func testContentAreaChipItemsKeepsSkillsAndAttachmentsInOneSequence() {
        let attachmentId = UUID()
        let items = ContentAreaChipItem.items(
            selectedSkills: [
                makeSkill(name: "browse-the-web"),
                makeSkill(name: "explore")
            ],
            attachments: [
                makeAttachment(id: attachmentId)
            ]
        )

        XCTAssertEqual(items.map(\.id), [
            "skill:browse-the-web",
            "skill:explore",
            "attachment:\(attachmentId.uuidString)"
        ])
    }

    func testContentAreaChipItemsKeepsAttachmentsAfterAllSkillsWithoutLineBreakSentinel() {
        let attachment = makeAttachment(fileName: "notes.txt")
        let items = ContentAreaChipItem.items(
            selectedSkills: [makeSkill(name: "find-skill")],
            attachments: [attachment]
        )

        XCTAssertEqual(items.count, 2)
        guard case .skill(let skill) = items[0] else {
            XCTFail("Expected first chip to be a skill")
            return
        }
        guard case .attachment(let stagedAttachment) = items[1] else {
            XCTFail("Expected second chip to be an attachment")
            return
        }
        XCTAssertEqual(skill.name, "find-skill")
        XCTAssertEqual(stagedAttachment.fileName, "notes.txt")
    }

    func testAttachmentBubbleConstructsForDocumentChip() {
        let view = AttachmentBubble(
            attachment: makeAttachment(type: .document, mimeType: "text/plain", fileName: "test.txt"),
            capability: .default,
            onRemove: {}
        )

        render(view)
    }

    func testAttachmentBubbleConstructsForPDFWarningChip() {
        let attachment = makeAttachment(
            type: .pdf,
            mimeType: "application/pdf",
            fileName: "report.pdf"
        )
        XCTAssertNotNil(attachment.warningText(for: pdfLimitedCapability))

        let view = AttachmentBubble(
            attachment: attachment,
            capability: pdfLimitedCapability,
            onRemove: {}
        )

        render(view)
    }

    func testAttachmentBubbleConstructsForImageChip() {
        let view = AttachmentBubble(
            attachment: makeAttachment(
                type: .image,
                mimeType: "image/png",
                fileName: "photo.png"
            ),
            capability: .default,
            onRemove: {}
        )

        render(view)
    }

    func testAttachmentBubbleConstructsWithLongTruncatingFilename() {
        let view = AttachmentBubble(
            attachment: makeAttachment(
                type: .document,
                mimeType: "text/plain",
                fileName: "a-very-long-file-name-that-should-truncate-in-the-chip.txt"
            ),
            capability: .default,
            onRemove: {}
        )

        render(view)
    }

    func testAttachmentBubbleShrinksShortFilenamesBelowTruncationWidth() {
        let shortChip = AttachmentBubble(
            attachment: makeAttachment(fileName: "a.txt"),
            capability: .default,
            onRemove: {}
        )
        let longChip = AttachmentBubble(
            attachment: makeAttachment(fileName: "a-very-long-file-name-that-should-truncate.txt"),
            capability: .default,
            onRemove: {}
        )

        XCTAssertLessThan(measuredWidth(shortChip), measuredWidth(longChip))
    }
}
