import XCTest
@testable import TronMobile

/// Tests for Attachment model and AttachmentType
/// TDD: Tests for the unified attachment data model
final class AttachmentTests: XCTestCase {

    // MARK: - AttachmentType Tests

    func testAttachmentTypeFromMimeType_jpeg() {
        let type = AttachmentType.from(mimeType: "image/jpeg")
        XCTAssertEqual(type, .image)
    }

    func testAttachmentTypeFromMimeType_png() {
        let type = AttachmentType.from(mimeType: "image/png")
        XCTAssertEqual(type, .image)
    }

    func testAttachmentTypeFromMimeType_gif() {
        let type = AttachmentType.from(mimeType: "image/gif")
        XCTAssertEqual(type, .image)
    }

    func testAttachmentTypeFromMimeType_webp() {
        let type = AttachmentType.from(mimeType: "image/webp")
        XCTAssertEqual(type, .image)
    }

    func testAttachmentTypeFromMimeType_pdf() {
        let type = AttachmentType.from(mimeType: "application/pdf")
        XCTAssertEqual(type, .pdf)
    }

    func testAttachmentTypeFromMimeType_plainText() {
        let type = AttachmentType.from(mimeType: "text/plain")
        XCTAssertEqual(type, .document)
    }

    func testAttachmentTypeFromMimeType_json() {
        let type = AttachmentType.from(mimeType: "application/json")
        XCTAssertEqual(type, .document)
    }

    func testAttachmentTypeFromMimeType_unknownDefaultsToDocument() {
        let type = AttachmentType.from(mimeType: "application/octet-stream")
        XCTAssertEqual(type, .document)
    }

    // MARK: - Attachment Property Tests

    func testAttachment_isImage_true() {
        let attachment = Attachment(
            type: .image,
            data: Data(),
            mimeType: "image/jpeg",
            fileName: nil
        )
        XCTAssertTrue(attachment.isImage)
        XCTAssertFalse(attachment.isPDF)
        XCTAssertFalse(attachment.isDocument)
    }

    func testAttachment_isPDF_true() {
        let attachment = Attachment(
            type: .pdf,
            data: Data(),
            mimeType: "application/pdf",
            fileName: "report.pdf"
        )
        XCTAssertFalse(attachment.isImage)
        XCTAssertTrue(attachment.isPDF)
        XCTAssertFalse(attachment.isDocument)
    }

    func testAttachment_isDocument_true() {
        let attachment = Attachment(
            type: .document,
            data: Data(),
            mimeType: "text/plain",
            fileName: "notes.txt"
        )
        XCTAssertFalse(attachment.isImage)
        XCTAssertFalse(attachment.isPDF)
        XCTAssertTrue(attachment.isDocument)
    }

    // MARK: - Display Name Tests

    func testAttachment_displayName_withFileName() {
        let attachment = Attachment(
            type: .pdf,
            data: Data(),
            mimeType: "application/pdf",
            fileName: "report.pdf"
        )
        XCTAssertEqual(attachment.displayName, "report.pdf")
    }

    func testAttachment_displayName_imageWithoutFileName() {
        let attachment = Attachment(
            type: .image,
            data: Data(),
            mimeType: "image/png",
            fileName: nil
        )
        XCTAssertEqual(attachment.displayName, "Image")
    }

    func testAttachment_displayName_pdfWithoutFileName() {
        let attachment = Attachment(
            type: .pdf,
            data: Data(),
            mimeType: "application/pdf",
            fileName: nil
        )
        XCTAssertEqual(attachment.displayName, "PDF")
    }

    func testAttachment_displayName_documentWithoutFileName() {
        let attachment = Attachment(
            type: .document,
            data: Data(),
            mimeType: "text/plain",
            fileName: nil
        )
        XCTAssertEqual(attachment.displayName, "Document")
    }

    // MARK: - Original Size Tests

    func testAttachment_originalSize_defaultsToDataCount() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let attachment = Attachment(
            type: .image,
            data: data,
            mimeType: "image/jpeg",
            fileName: nil
        )
        XCTAssertEqual(attachment.originalSize, 5)
    }

    func testAttachment_originalSize_usesExplicitValue() {
        let data = Data([0x01, 0x02])
        let attachment = Attachment(
            type: .image,
            data: data,
            mimeType: "image/jpeg",
            fileName: nil,
            originalSize: 1000
        )
        XCTAssertEqual(attachment.originalSize, 1000)
    }

    // MARK: - Identifiable Tests

    func testAttachment_hasUniqueId() {
        let attachment1 = Attachment(type: .image, data: Data(), mimeType: "image/png", fileName: nil)
        let attachment2 = Attachment(type: .image, data: Data(), mimeType: "image/png", fileName: nil)
        XCTAssertNotEqual(attachment1.id, attachment2.id)
    }

    // MARK: - Equatable Tests

    func testAttachment_equality_sameId() {
        let id = UUID()
        let data = Data([0x01, 0x02])
        let a1 = Attachment(
            id: id,
            type: .image,
            data: data,
            mimeType: "image/png",
            fileName: "test.png",
            originalSize: 100
        )
        let a2 = Attachment(
            id: id,
            type: .image,
            data: data,
            mimeType: "image/png",
            fileName: "test.png",
            originalSize: 100
        )
        XCTAssertEqual(a1, a2)
    }

    func testAttachment_inequality_differentId() {
        let data = Data([0x01, 0x02])
        let a1 = Attachment(type: .image, data: data, mimeType: "image/png", fileName: "test.png")
        let a2 = Attachment(type: .image, data: data, mimeType: "image/png", fileName: "test.png")
        XCTAssertNotEqual(a1, a2) // Different UUIDs
    }

    // MARK: - Convenience Initializer Tests

    func testAttachment_fromData_detectsImageType() {
        let attachment = Attachment.from(
            data: Data(),
            mimeType: "image/jpeg",
            fileName: "photo.jpg"
        )
        XCTAssertEqual(attachment.type, .image)
    }

    func testAttachment_fromData_detectsPdfType() {
        let attachment = Attachment.from(
            data: Data(),
            mimeType: "application/pdf",
            fileName: "doc.pdf"
        )
        XCTAssertEqual(attachment.type, .pdf)
    }

    func testAttachment_fromData_detectsDocumentType() {
        let attachment = Attachment.from(
            data: Data(),
            mimeType: "text/plain",
            fileName: "notes.txt"
        )
        XCTAssertEqual(attachment.type, .document)
    }

    // MARK: - Size Formatting Tests

    func testAttachment_formattedSize_bytes() {
        let attachment = Attachment(
            type: .image,
            data: Data([0x01, 0x02, 0x03]),
            mimeType: "image/png",
            fileName: nil
        )
        XCTAssertEqual(attachment.formattedSize, "3 B")
    }

    func testAttachment_formattedSize_kilobytes() {
        let data = Data(repeating: 0, count: 2048)
        let attachment = Attachment(
            type: .image,
            data: data,
            mimeType: "image/png",
            fileName: nil
        )
        XCTAssertEqual(attachment.formattedSize, "2 KB")
    }

    func testAttachment_formattedSize_megabytes() {
        let data = Data(repeating: 0, count: 2 * 1024 * 1024)
        let attachment = Attachment(
            type: .pdf,
            data: data,
            mimeType: "application/pdf",
            fileName: nil
        )
        XCTAssertEqual(attachment.formattedSize, "2.0 MB")
    }
}
