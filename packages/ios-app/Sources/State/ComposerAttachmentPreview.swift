import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ComposerAttachmentPreviewPolicy {
    static let maximumPixelDimension = 192
    static let maximumEncodedBytes = 1 * 1_048_576

    static func prepare(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            prepareSynchronously(data)
        }.value
    }

    nonisolated static func prepareSynchronously(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
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
}
