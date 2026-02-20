import XCTest
@testable import TronMobile

/// Tests for ImageCompressor utility
/// TDD: Tests for image compression to meet size constraints
final class ImageCompressorTests: XCTestCase {

    // MARK: - Basic Compression Tests

    func testCompress_producesNonNilResult() async {
        let image = createTestImage(size: CGSize(width: 100, height: 100))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        XCTAssertFalse(result!.data.isEmpty)
    }

    func testCompress_producesDataUnderTargetSize() async {
        // Create a moderately large test image
        let image = createTestImage(size: CGSize(width: 500, height: 500))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.data.count, ImageCompressor.targetSizeBytes)
    }

    func testCompress_smallImagePassesThrough() async {
        // Create a tiny image that's already under target
        let image = createTestImage(size: CGSize(width: 50, height: 50))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.data.count, ImageCompressor.targetSizeBytes)
    }

    // MARK: - Resize Tests

    func testCompress_resizesLargeImages() async {
        // Create an oversized image (3000x2000)
        let image = createTestImage(size: CGSize(width: 3000, height: 2000))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        // Verify dimensions were reduced (check via compressionInfo)
        XCTAssertTrue(result!.compressionInfo.contains("resized"))
    }

    func testCompress_doesNotResizeSmallImages() async {
        // Create an image under the max dimension
        let image = createTestImage(size: CGSize(width: 1000, height: 800))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        // Should not contain "resized" if dimensions were acceptable
        XCTAssertFalse(result!.compressionInfo.contains("resized"))
    }

    // MARK: - JPEG Quality Tests

    func testCompress_outputIsJPEG() async {
        let image = createTestImage(size: CGSize(width: 200, height: 200))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        // JPEG files start with FF D8
        let jpegHeader: [UInt8] = [0xFF, 0xD8]
        let resultHeader = Array(result!.data.prefix(2))
        XCTAssertEqual(resultHeader, jpegHeader, "Output should be JPEG format")
    }

    func testCompress_mimeTypeIsJPEG() async {
        let image = createTestImage(size: CGSize(width: 200, height: 200))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.mimeType, "image/jpeg")
    }

    // MARK: - Compression Info Tests

    func testCompress_compressionInfoContainsQuality() async {
        let image = createTestImage(size: CGSize(width: 200, height: 200))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.compressionInfo.contains("quality"))
    }

    func testCompress_compressionInfoContainsSize() async {
        let image = createTestImage(size: CGSize(width: 200, height: 200))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        // Should contain size info like "KB" or "B"
        XCTAssertTrue(
            result!.compressionInfo.contains("KB") || result!.compressionInfo.contains("B"),
            "compressionInfo should contain size unit"
        )
    }

    // MARK: - Target Size Constant Tests

    func testTargetSizeBytes_is100KB() {
        XCTAssertEqual(ImageCompressor.targetSizeBytes, 100 * 1024)
    }

    func testMaxDimension_is2048() {
        XCTAssertEqual(ImageCompressor.maxDimension, 2048)
    }

    // MARK: - Edge Cases

    func testCompress_handlesVeryLargeImage() async {
        // Create a very large image (4000x4000)
        let image = createTestImage(size: CGSize(width: 4000, height: 4000))

        let result = await ImageCompressor.compress(image)

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.data.count, ImageCompressor.targetSizeBytes)
    }

    func testCompress_handlesNonSquareImage() async {
        // Very wide image
        let wideImage = createTestImage(size: CGSize(width: 3000, height: 500))

        let wideResult = await ImageCompressor.compress(wideImage)

        XCTAssertNotNil(wideResult)
        XCTAssertLessThanOrEqual(wideResult!.data.count, ImageCompressor.targetSizeBytes)

        // Very tall image
        let tallImage = createTestImage(size: CGSize(width: 500, height: 3000))

        let tallResult = await ImageCompressor.compress(tallImage)

        XCTAssertNotNil(tallResult)
        XCTAssertLessThanOrEqual(tallResult!.data.count, ImageCompressor.targetSizeBytes)
    }

    func testCompress_handles1x1Image() async {
        let tinyImage = createTestImage(size: CGSize(width: 1, height: 1))

        let result = await ImageCompressor.compress(tinyImage)

        XCTAssertNotNil(result)
    }

    // MARK: - Helpers

    private func createTestImage(size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }

        // Fill with a gradient-like pattern to create some complexity
        let context = UIGraphicsGetCurrentContext()!
        for y in stride(from: 0, to: Int(size.height), by: 10) {
            for x in stride(from: 0, to: Int(size.width), by: 10) {
                let hue = CGFloat(x + y) / CGFloat(size.width + size.height)
                UIColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1.0).setFill()
                context.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }

        return UIGraphicsGetImageFromCurrentImageContext()!
    }
}
