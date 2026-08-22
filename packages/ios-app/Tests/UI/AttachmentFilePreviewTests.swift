import Foundation
import Testing
import UIKit
@testable import TronMobile

@Suite("Attachment file previews")
struct AttachmentFilePreviewTests {
    @Test("classification admits formatted text, code, PDF, and fails closed")
    func classification() {
        #expect(AttachmentFilePreviewPolicy.maximumTextBytes == 320_000)
        #expect(AttachmentFilePreviewPolicy.maximumPDFPages == 512)
        #expect(AttachmentFilePreviewPolicy.kind(name: "README.md", mimeType: "application/octet-stream") == .markdown)
        #expect(AttachmentFilePreviewPolicy.kind(name: "notes.txt", mimeType: "text/plain; charset=utf-8") == .plainText)
        #expect(AttachmentFilePreviewPolicy.kind(name: "payload.json", mimeType: "application/json") == .code(language: "json"))
        #expect(AttachmentFilePreviewPolicy.kind(name: "script", mimeType: "text/x-shellscript") == .code(language: nil))
        #expect(AttachmentFilePreviewPolicy.kind(name: "module", mimeType: "text/javascript") == .code(language: nil))
        #expect(AttachmentFilePreviewPolicy.kind(name: "report.pdf", mimeType: "application/octet-stream") == .pdf)
        #expect(AttachmentFilePreviewPolicy.kind(name: "archive.zip", mimeType: "application/zip") == .unsupported)
    }

    @Test("markdown prepares the established immutable document off the bounded source")
    func markdownPreparation() async throws {
        let prepared = try await AttachmentFilePreviewPolicy.prepare(
            data: Data("# Heading\n\n```swift\nlet value = 1\n```".utf8),
            name: "README.md",
            mimeType: "text/markdown"
        )
        guard case .markdown(let document) = prepared.content else {
            Issue.record("Expected Markdown content")
            return
        }
        #expect(!prepared.isTruncated)
        #expect(document.blocks.count == 2)
    }

    @Test("plain and code text remain exact selectable sources")
    func textPreparation() throws {
        let plain = try AttachmentFilePreviewPolicy.prepareSynchronously(
            data: Data("first  line\nsecond".utf8),
            name: "notes.txt",
            mimeType: "text/plain"
        )
        guard case .plainText(let plainText) = plain.content else {
            Issue.record("Expected plain text")
            return
        }
        #expect(plainText == "first  line\nsecond")

        let code = try AttachmentFilePreviewPolicy.prepareSynchronously(
            data: Data("func value() {\n    return\n}".utf8),
            name: "main.swift",
            mimeType: "text/x-swift"
        )
        guard case .code(let codeText) = code.content else {
            Issue.record("Expected code")
            return
        }
        #expect(codeText == "func value() {\n    return\n}")
    }

    @Test("text prefix backs off to a valid Unicode boundary and marks omission")
    func unicodeSafeTruncation() throws {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: AttachmentFilePreviewPolicy.maximumTextBytes - 1)
        bytes.append(Data("🙂tail".utf8))
        let prepared = try AttachmentFilePreviewPolicy.prepareSynchronously(
            data: bytes,
            name: "large.txt",
            mimeType: "text/plain"
        )
        guard case .plainText(let text) = prepared.content else {
            Issue.record("Expected plain text")
            return
        }
        #expect(prepared.isTruncated)
        #expect(text.utf8.count == AttachmentFilePreviewPolicy.maximumTextBytes - 1)
        #expect(!text.contains("�"))
        #expect(throws: AttachmentFilePreviewError.invalidText) {
            try AttachmentFilePreviewPolicy.prepareSynchronously(
                data: Data([0x61, 0xF0]),
                name: "malformed.txt",
                mimeType: "text/plain"
            )
        }
        #expect(throws: AttachmentFilePreviewError.invalidText) {
            try AttachmentFilePreviewPolicy.prepareSynchronously(
                data: Data([0x61, 0x00, 0x62]),
                name: "binary.txt",
                mimeType: "text/plain"
            )
        }
    }

    @Test("PDF preparation preserves multiple pages and rejects pathological counts")
    func pdfPreparation() throws {
        let prepared = try AttachmentFilePreviewPolicy.prepareSynchronously(
            data: pdfData(pageCount: 2),
            name: "report.pdf",
            mimeType: "application/pdf"
        )
        guard case .pdf(let pdf) = prepared.content else {
            Issue.record("Expected PDF")
            return
        }
        #expect(pdf.pageCount == 2)
        #expect(pdf.document.pageCount == 2)

        #expect(throws: AttachmentFilePreviewError.tooManyPDFPages) {
            try AttachmentFilePreviewPolicy.prepareSynchronously(
                data: pdfData(pageCount: AttachmentFilePreviewPolicy.maximumPDFPages + 1),
                name: "pathological.pdf",
                mimeType: "application/pdf"
            )
        }
        #expect(throws: AttachmentFilePreviewError.invalidPDF) {
            try AttachmentFilePreviewPolicy.prepareSynchronously(
                data: Data("not pdf".utf8),
                name: "invalid.pdf",
                mimeType: "application/pdf"
            )
        }
    }

    @Test("unsupported content fails closed")
    func unsupported() {
        #expect(throws: AttachmentFilePreviewError.unsupported) {
            try AttachmentFilePreviewPolicy.prepareSynchronously(
                data: Data([1, 2, 3]),
                name: "archive.zip",
                mimeType: "application/zip"
            )
        }
    }

    private func pdfData(pageCount: Int) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        return renderer.pdfData { context in
            for _ in 0..<pageCount { context.beginPage() }
        }
    }
}
