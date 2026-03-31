import UIKit

/// Result of image processing.
struct ImageProcessingResult {
    let data: Data
    let mimeType: String
    let wasConverted: Bool
    let info: String
}

/// Processes images for sending to LLM providers, preserving format when possible.
struct ImageProcessor {

    /// WebSocket transport limit is 2MB. After base64 (+33%) and JSON overhead,
    /// raw image data must stay under this to avoid disconnection.
    static let transportMaxBytes = 1_400_000 // ~1.4MB raw → ~1.87MB base64

    /// Detect MIME type from data magic bytes.
    static func detectMimeType(from data: Data) -> String {
        guard data.count >= 12 else { return "image/jpeg" }
        let bytes = [UInt8](data.prefix(12))

        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "image/png"
        }
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "image/gif"
        }
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46,
           bytes.count >= 12,
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "image/webp"
        }
        return "image/jpeg"
    }

    /// Process an image with provider-aware limits, preserving format when possible.
    static func process(
        originalData: Data,
        mimeType: String,
        limits: ProviderImageLimits
    ) async -> ImageProcessingResult? {
        guard !originalData.isEmpty else { return nil }
        guard let image = UIImage(data: originalData) else { return nil }

        // Clamp to WebSocket transport limit so the base64 payload fits
        let effectiveMaxBytes = min(limits.maxBytes, transportMaxBytes)

        let formatSupported = limits.supportedFormats.contains(mimeType)
        let dimensions = max(image.size.width, image.size.height)
        let underDimensionLimit = dimensions <= limits.maxDimension
        let underSizeLimit = originalData.count <= effectiveMaxBytes

        // Fast path: format supported, within all limits — pass through as-is
        if formatSupported && underDimensionLimit && underSizeLimit {
            return ImageProcessingResult(
                data: originalData,
                mimeType: mimeType,
                wasConverted: false,
                info: "passthrough, \(formatBytes(originalData.count))"
            )
        }

        // GIF special handling: can't re-encode animated GIFs
        if mimeType == "image/gif" && formatSupported {
            if underSizeLimit && underDimensionLimit {
                return ImageProcessingResult(
                    data: originalData,
                    mimeType: mimeType,
                    wasConverted: false,
                    info: "gif passthrough"
                )
            }
            // Over limits — extract first frame, convert to JPEG
            return await compressToJpeg(image: image, maxDimension: limits.maxDimension, maxBytes: effectiveMaxBytes, note: "gif first frame")
        }

        // Try to preserve format with resizing if format is supported
        if formatSupported {
            if let result = await resizeAndReencode(
                image: image,
                originalData: originalData,
                mimeType: mimeType,
                maxDimension: limits.maxDimension,
                maxBytes: effectiveMaxBytes
            ) {
                return result
            }
        }

        // Fallback: convert to JPEG
        return await compressToJpeg(image: image, maxDimension: limits.maxDimension, maxBytes: effectiveMaxBytes, note: "format conversion")
    }

    // MARK: - Private

    private static func resizeAndReencode(
        image: UIImage,
        originalData: Data,
        mimeType: String,
        maxDimension: CGFloat,
        maxBytes: Int
    ) async -> ImageProcessingResult? {
        var workingImage = image
        var info = ""

        // Resize if needed
        let maxDim = max(image.size.width, image.size.height)
        if maxDim > maxDimension {
            let scale = maxDimension / maxDim
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            workingImage = resize(image, to: newSize)
            info += "resized to \(Int(newSize.width))x\(Int(newSize.height)), "
        }

        // Re-encode in same format
        let encoded: Data?
        switch mimeType {
        case "image/png":
            encoded = workingImage.pngData()
        case "image/jpeg":
            encoded = workingImage.jpegData(compressionQuality: 0.85)
        default:
            encoded = nil
        }

        if let data = encoded, data.count <= maxBytes {
            info += "\(formatBytes(data.count))"
            return ImageProcessingResult(data: data, mimeType: mimeType, wasConverted: false, info: info)
        }

        // PNG still too large after resize — try reducing dimensions further
        if mimeType == "image/png", let data = encoded, data.count > maxBytes {
            var scale: CGFloat = 0.8
            while scale >= 0.3 {
                let reduced = resize(workingImage, to: CGSize(
                    width: workingImage.size.width * scale,
                    height: workingImage.size.height * scale
                ))
                if let pngData = reduced.pngData(), pngData.count <= maxBytes {
                    return ImageProcessingResult(
                        data: pngData,
                        mimeType: "image/png",
                        wasConverted: false,
                        info: "resized png, \(formatBytes(pngData.count))"
                    )
                }
                scale -= 0.1
            }
        }

        return nil // Caller will fall through to JPEG
    }

    private static func compressToJpeg(
        image: UIImage,
        maxDimension: CGFloat,
        maxBytes: Int,
        note: String
    ) async -> ImageProcessingResult? {
        var workingImage = image
        var info = note + ", "

        // Step 1: Resize if needed
        let maxDim = max(image.size.width, image.size.height)
        if maxDim > maxDimension {
            let scale = maxDimension / maxDim
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            workingImage = resize(image, to: newSize)
            info += "resized to \(Int(newSize.width))x\(Int(newSize.height)), "
        }

        // Step 2: Progressive quality reduction
        var quality: CGFloat = 0.85
        var data = workingImage.jpegData(compressionQuality: quality)

        while let d = data, d.count > maxBytes, quality > 0.1 {
            quality -= 0.1
            data = workingImage.jpegData(compressionQuality: quality)
        }

        if let d = data, d.count > maxBytes, quality <= 0.1 {
            quality = 0.08
            while quality >= 0.01 {
                data = workingImage.jpegData(compressionQuality: quality)
                if let d = data, d.count <= maxBytes { break }
                quality -= 0.02
            }
        }

        // Step 3: Dimension reduction fallback
        if let d = data, d.count > maxBytes {
            var scale: CGFloat = 0.9
            while scale >= 0.3 {
                let reduced = resize(workingImage, to: CGSize(
                    width: workingImage.size.width * scale,
                    height: workingImage.size.height * scale
                ))
                data = reduced.jpegData(compressionQuality: max(quality, 0.05))
                if let d = data, d.count <= maxBytes {
                    break
                }
                scale -= 0.1
            }
        }

        guard let finalData = data else { return nil }
        info += "quality \(Int(quality * 100))%, \(formatBytes(finalData.count))"

        return ImageProcessingResult(
            data: finalData,
            mimeType: "image/jpeg",
            wasConverted: true,
            info: info
        )
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

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
