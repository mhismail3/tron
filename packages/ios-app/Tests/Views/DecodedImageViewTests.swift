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
}
