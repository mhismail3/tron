import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ComposerAttachmentPreviewPolicy {
    static let maximumPixelDimension = 192
    static let maximumEncodedBytes = 1 * 1_048_576

    static func prepare(
        _ data: Data,
        mimeType: String? = nil,
        name: String? = nil
    ) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            prepareSynchronously(data, mimeType: mimeType, name: name)
        }.value
    }

    nonisolated static func prepareSynchronously(
        _ data: Data,
        mimeType: String? = nil,
        name: String? = nil
    ) -> Data? {
        guard let image = imageThumbnail(data)
                ?? pdfThumbnail(data, mimeType: mimeType, name: name)
                ?? textThumbnail(data, mimeType: mimeType, name: name),
              image.width <= maximumPixelDimension,
              image.height <= maximumPixelDimension else { return nil }
        let (decodedBytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, decodedBytes <= maximumEncodedBytes else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumEncodedBytes else { return nil }
        return output as Data
    }

    private nonisolated static func imageThumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // Index zero is the first image or document page. ImageIO covers photos,
        // PDFs, and other platform-supported paged formats without loading later
        // pages into the composer.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func pdfThumbnail(
        _ data: Data,
        mimeType: String?,
        name: String?
    ) -> CGImage? {
        let isPDF = mimeType?.lowercased() == "application/pdf"
            || name.map { URL(fileURLWithPath: $0).pathExtension.lowercased() == "pdf" } == true
            || data.starts(with: Data("%PDF-".utf8))
        guard isPDF,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let side = maximumPixelDimension
        guard let context = bitmapContext(side: side) else { return nil }
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = CGRect(x: 8, y: 8, width: side - 16, height: side - 16)
        context.concatenate(page.getDrawingTransform(
            .mediaBox,
            rect: destination,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private nonisolated static func textThumbnail(
        _ data: Data,
        mimeType: String?,
        name: String?
    ) -> CGImage? {
        guard isText(mimeType: mimeType, name: name) else { return nil }
        let bounded = data.prefix(64 * 1_024)
        guard let text = String(data: bounded, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let side = maximumPixelDimension
        guard let context = bitmapContext(side: side) else { return nil }
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, 9, nil),
            kCTForegroundColorAttributeName: CGColor(gray: 0.14, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        guard let attributed else { return nil }
        let frameSetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 10, y: 10, width: side - 20, height: side - 20), transform: nil)
        let frame = CTFramesetterCreateFrame(frameSetter, CFRange(), path, nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    private nonisolated static func bitmapContext(side: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private nonisolated static func isText(mimeType: String?, name: String?) -> Bool {
        if mimeType?.lowercased().hasPrefix("text/") == true { return true }
        let extensions: Set<String> = [
            "csv", "ips", "js", "json", "jsonl", "log", "md", "py", "sh",
            "swift", "text", "toml", "ts", "txt", "xml", "yaml", "yml",
        ]
        let pathExtension = name.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
        return pathExtension.map(extensions.contains) == true
    }
}
