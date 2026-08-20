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

    @Test("plain text renders a bounded first-page preview only with file metadata")
    func textPreview() throws {
        let data = Data("First line\nSecond line\nThird line".utf8)
        let preview = try #require(ComposerAttachmentPreviewPolicy.prepareSynchronously(
            data,
            mimeType: "text/plain",
            name: "notes.txt"
        ))
        #expect(preview.count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes)
        #expect(CGImageSourceCreateWithData(preview as CFData, nil) != nil)
    }

    @Test("unknown binary data does not become a preview")
    func invalidInput() {
        #expect(ComposerAttachmentPreviewPolicy.prepareSynchronously(Data("not an image".utf8)) == nil)
    }
}
