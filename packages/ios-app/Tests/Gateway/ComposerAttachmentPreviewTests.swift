import Foundation
import ImageIO
import Testing
@testable import TronMobile

@Suite("Composer attachment previews")
struct ComposerAttachmentPreviewTests {
    @Test("large and oriented images become bounded display-ready previews")
    func boundedPreview() throws {
        let fixture = try SessionScenarioBuilder(seed: 81).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 1_200,
            pixelHeight: 800,
            orientation: .right
        )
        let preview = try #require(
            ComposerAttachmentPreviewPolicy.prepareSynchronously(fixture.encodedData)
        )
        #expect(preview.count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes)
        let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(width <= ComposerAttachmentPreviewPolicy.maximumPixelDimension)
        #expect(height <= ComposerAttachmentPreviewPolicy.maximumPixelDimension)
        #expect(height > width)
    }

    @Test("non-images do not retain arbitrary attachment payloads")
    func invalidInput() {
        #expect(ComposerAttachmentPreviewPolicy.prepareSynchronously(Data("not an image".utf8)) == nil)
    }
}
