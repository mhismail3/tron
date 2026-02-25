import SwiftUI

// MARK: - Decoded Image View

/// Decodes image data on a background thread to avoid main-thread jank.
/// Uses `.task(id:)` for automatic cancellation on disappear.
/// Caches decoded images by data identity to avoid re-decoding on scroll.
struct DecodedImageView: View {
    let data: Data
    let size: CGSize

    @State private var uiImage: UIImage?

    private nonisolated(unsafe) static let cache: NSCache<NSData, UIImage> = {
        let c = NSCache<NSData, UIImage>()
        c.countLimit = 100
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
            let scale = UIScreen.main.scale
            uiImage = await Self.decodeImage(data, fitting: size, scale: scale)
        }
    }

    /// Decode on a detached task to avoid blocking the main thread.
    /// Uses `preparingThumbnail(of:)` to downscale large images during decode.
    /// Returns cached result on repeat calls for the same data.
    static func decodeImage(_ data: Data, fitting size: CGSize, scale: CGFloat = 2.0) async -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }

        let result = await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil as UIImage? }
            let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
            return image.preparingThumbnail(of: targetSize) ?? image
        }.value

        if let result { cache.setObject(result, forKey: key) }
        return result
    }
}
