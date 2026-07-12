import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class AttachmentImagePreparerTests: XCTestCase {
    func testPreparerCompressesAndResizesToServerPolicy() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_000, height: 600)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 600))
        }
        let sourceData = try XCTUnwrap(source.pngData())
        let limits = ProviderImageLimits(
            maxDimension: 120,
            maxBytes: 20_000,
            supportedFormats: ["image/jpeg"]
        )

        let prepared = await AttachmentImagePreparer.prepare(
            data: sourceData,
            declaredMimeType: "image/png",
            fileName: "photo.png",
            limits: limits
        )
        let attachment = try XCTUnwrap(prepared)
        let processedImage = try XCTUnwrap(UIImage(data: attachment.data))

        XCTAssertEqual(attachment.type, .image)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.fileName, "photo.png")
        XCTAssertEqual(attachment.originalSize, sourceData.count)
        XCTAssertTrue(attachment.wasConverted)
        XCTAssertLessThanOrEqual(attachment.data.count, limits.maxBytes)
        XCTAssertLessThanOrEqual(max(processedImage.size.width, processedImage.size.height), 120)
    }

    func testPreparerRejectsSourceAboveDecodeBound() async {
        let oversized = Data(repeating: 0, count: ImageProcessor.maximumSourceBytes + 1)
        let attachment = await AttachmentImagePreparer.prepare(
            data: oversized,
            declaredMimeType: "image/jpeg",
            limits: .default
        )
        XCTAssertNil(attachment)
    }

    func testMimeDetectionRecognizesHeicBrand() {
        let data = Data([0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        XCTAssertEqual(ImageProcessor.detectMimeType(from: data), "image/heic")
    }
}
