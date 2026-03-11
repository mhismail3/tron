import UIKit

/// Result of image compression
struct CompressionResult {
    /// Compressed image data
    let data: Data
    /// MIME type of the output (always JPEG)
    let mimeType: String
    /// Human-readable description of compression applied
    let compressionInfo: String
}

/// Utility for compressing images to meet size constraints
struct ImageCompressor {
    /// Target compressed size in bytes (100KB)
    static let targetSizeBytes = 100 * 1024

    /// Maximum dimension (width or height) before resizing
    static let maxDimension: CGFloat = 2048

    /// Compress an image to meet size constraints
    /// - Parameter image: The image to compress
    /// - Returns: Compression result with data and info, or nil if compression fails
    static func compress(_ image: UIImage) async -> CompressionResult? {
        var workingImage = image
        var info = ""

        // Step 1: Resize if dimensions exceed max
        let maxDim = max(image.size.width, image.size.height)
        if maxDim > maxDimension {
            let scale = maxDimension / maxDim
            let newSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            workingImage = resize(image, to: newSize)
            info += "resized to \(Int(newSize.width))x\(Int(newSize.height)), "
        }

        // Step 2: Progressive JPEG compression
        var quality: CGFloat = 0.8
        var data = workingImage.jpegData(compressionQuality: quality)

        // Coarse pass: reduce quality in 0.1 steps
        while let d = data, d.count > targetSizeBytes, quality > 0.1 {
            quality -= 0.1
            data = workingImage.jpegData(compressionQuality: quality)
        }

        // Fine pass: if still over target at low quality, try smaller steps down to 0.01
        if let d = data, d.count > targetSizeBytes, quality <= 0.1 {
            quality = 0.08
            while quality >= 0.01 {
                data = workingImage.jpegData(compressionQuality: quality)
                if let d = data, d.count <= targetSizeBytes { break }
                quality -= 0.02
            }
        }

        // Resize fallback: if still over target, progressively shrink dimensions
        if let d = data, d.count > targetSizeBytes {
            var scale: CGFloat = 0.9
            while scale >= 0.3 {
                let reduced = resize(workingImage, to: CGSize(
                    width: workingImage.size.width * scale,
                    height: workingImage.size.height * scale
                ))
                data = reduced.jpegData(compressionQuality: max(quality, 0.05))
                if let d = data, d.count <= targetSizeBytes {
                    info += "downscaled to \(Int(workingImage.size.width * scale))x\(Int(workingImage.size.height * scale)), "
                    break
                }
                scale -= 0.1
            }
        }

        guard let finalData = data else { return nil }

        info += "quality \(Int(quality * 100))%, \(formatBytes(finalData.count))"

        return CompressionResult(
            data: finalData,
            mimeType: "image/jpeg",
            compressionInfo: info
        )
    }

    /// Resize an image to the specified size.
    /// Uses UIGraphicsImageRenderer (non-deprecated) which respects device scale.
    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Format bytes into human-readable string
    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return "\(bytes / 1024) KB"
        } else {
            let mb = Double(bytes) / (1024 * 1024)
            return String(format: "%.1f MB", mb)
        }
    }
}
