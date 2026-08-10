import SwiftUI

// MARK: - Decoded Image View

/// Decodes image data on a background thread to avoid main-thread jank.
/// Uses `.task(id:)` for automatic cancellation on disappear.
/// Caches decoded images by data and requested pixel dimensions to avoid
/// re-decoding on scroll without stretching a thumbnail in a larger surface.
struct DecodedImageView: View {
    let data: Data
    let size: CGSize

    @Environment(\.displayScale) private var displayScale
    @State private var uiImage: UIImage?

    private nonisolated(unsafe) static let cache: NSCache<ImageDecodeCacheKey, UIImage> = {
        let c = NSCache<ImageDecodeCacheKey, UIImage>()
        c.countLimit = 100
        c.totalCostLimit = 96 * 1_024 * 1_024
        return c
    }()

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.tronSurfaceElevated
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: data) {
            uiImage = await Self.decodeImage(data, fitting: size, scale: displayScale)
        }
    }

    /// Decode through a serial actor to avoid blocking the main thread.
    /// Uses `preparingThumbnail(of:)` to downscale large images during decode.
    /// Returns cached result on repeat calls for the same data and target size.
    static func decodeImage(_ data: Data, fitting size: CGSize, scale: CGFloat = 2.0) async -> UIImage? {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let pixelSize = CGSize(
            width: max(1, (size.width * safeScale).rounded(.up)),
            height: max(1, (size.height * safeScale).rounded(.up))
        )
        let key = ImageDecodeCacheKey(data: data, pixelSize: pixelSize)
        if let cached = cache.object(forKey: key) { return cached }

        let result = await ImageDecodeWorker.shared.decode(data, fitting: pixelSize)

        if let result {
            let decodedByteCost = result.cgImage.map {
                $0.bytesPerRow * $0.height
            } ?? 0
            cache.setObject(result, forKey: key, cost: decodedByteCost)
        }
        return result
    }
}

private final class ImageDecodeCacheKey: NSObject {
    let data: NSData
    let pixelWidth: Int
    let pixelHeight: Int

    init(data: Data, pixelSize: CGSize) {
        self.data = data as NSData
        pixelWidth = Int(pixelSize.width)
        pixelHeight = Int(pixelSize.height)
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(data.hash)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ImageDecodeCacheKey else { return false }
        return pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && data.isEqual(other.data)
    }
}

private actor ImageDecodeWorker {
    static let shared = ImageDecodeWorker()

    func decode(_ data: Data, fitting size: CGSize) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingThumbnail(of: size) ?? image
    }
}
