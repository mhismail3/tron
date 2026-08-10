import Testing
import UIKit
import Foundation
@testable import TronMobile

// MARK: - DecodedImageView Tests

@Suite("DecodedImageView")
struct DecodedImageViewTests {

    /// Create a minimal valid PNG for testing.
    private static func makeTestPNG(width: Int = 100, height: Int = 100) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("Decodes valid PNG data to UIImage")
    func testDecodeValidPNG() async {
        let pngData = Self.makeTestPNG(width: 200, height: 150)
        let size = CGSize(width: 72, height: 72)
        let image = await DecodedImageView.decodeImage(pngData, fitting: size, scale: 2.0)
        #expect(image != nil)
    }

    @Test("Returns nil for invalid image data")
    func testDecodeInvalidData() async {
        let badData = Data("not an image".utf8)
        let image = await DecodedImageView.decodeImage(badData, fitting: CGSize(width: 72, height: 72))
        #expect(image == nil)
    }

    @Test("Returns nil for empty data")
    func testDecodeEmptyData() async {
        let image = await DecodedImageView.decodeImage(Data(), fitting: CGSize(width: 72, height: 72))
        #expect(image == nil)
    }

    @Test("Produces thumbnail sized to fit target")
    func testThumbnailSize() async {
        let pngData = Self.makeTestPNG(width: 1000, height: 1000)
        let size = CGSize(width: 56, height: 56)
        let scale: CGFloat = 2.0
        let image = await DecodedImageView.decodeImage(pngData, fitting: size, scale: scale)
        #expect(image != nil)
        if let image {
            let maxDimension = max(image.size.width, image.size.height)
            #expect(maxDimension <= 56 * scale + 1)
        }
    }

    @Test("Cache returns image on second decode of same data")
    func testCacheHit() async {
        let pngData = Self.makeTestPNG(width: 80, height: 80)
        let size = CGSize(width: 40, height: 40)

        let first = await DecodedImageView.decodeImage(pngData, fitting: size, scale: 2.0)
        #expect(first != nil)

        let second = await DecodedImageView.decodeImage(pngData, fitting: size, scale: 2.0)
        #expect(second != nil)

        // Both should be the same cached instance
        #expect(first === second)
    }

    @Test("Cache keeps a full preview distinct from its thumbnail")
    func testCacheSeparatesRequestedPixelDimensions() async {
        let pngData = Self.makeTestPNG(width: 600, height: 400)

        let thumbnail = await DecodedImageView.decodeImage(
            pngData,
            fitting: CGSize(width: 40, height: 40),
            scale: 1
        )
        let preview = await DecodedImageView.decodeImage(
            pngData,
            fitting: CGSize(width: 300, height: 300),
            scale: 1
        )

        #expect(thumbnail != nil)
        #expect(preview != nil)
        if let thumbnail, let preview {
            #expect(preview.size.width > thumbnail.size.width)
            #expect(preview !== thumbnail)
        }
    }
}
