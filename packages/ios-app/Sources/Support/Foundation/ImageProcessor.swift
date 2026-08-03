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
    /// Bound raw image decoding independently from the smaller effective
    /// model policy. Large camera/library images are accepted and compressed,
    /// but pathological files are rejected before UIKit allocation.
    static let maximumSourceBytes = 50 * 1024 * 1024

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
        if bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8...11], encoding: .ascii)
            if ["heic", "heix", "hevc", "hevx"].contains(brand) {
                return "image/heic"
            }
            if ["mif1", "msf1"].contains(brand) {
                return "image/heif"
            }
        }
        return "image/jpeg"
    }

    /// Process an image with provider-aware limits, preserving format when possible.
    static func process(
        originalData: Data,
        mimeType: String,
        limits: ProviderImageLimits
    ) async -> ImageProcessingResult? {
        guard !originalData.isEmpty, originalData.count <= maximumSourceBytes else { return nil }
        guard limits.maxDimension > 0, limits.maxBytes > 0 else { return nil }
        guard let image = UIImage(data: originalData) else { return nil }

        let formatSupported = limits.supportedFormats.contains(mimeType)
        let sourceSize = pixelSize(of: image)
        let dimensions = max(sourceSize.width, sourceSize.height)
        let underDimensionLimit = dimensions <= limits.maxDimension
        let underSizeLimit = originalData.count <= limits.maxBytes

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
            return await compressToJpeg(image: image, maxDimension: limits.maxDimension, maxBytes: limits.maxBytes, note: "gif first frame")
        }

        // Try to preserve format with resizing if format is supported
        if formatSupported {
            if let result = await resizeAndReencode(
                image: image,
                originalData: originalData,
                mimeType: mimeType,
                maxDimension: limits.maxDimension,
                maxBytes: limits.maxBytes
            ) {
                return result
            }
        }

        // Convert to JPEG when the source format cannot meet the byte budget.
        return await compressToJpeg(image: image, maxDimension: limits.maxDimension, maxBytes: limits.maxBytes, note: "format conversion")
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
        let imageSize = pixelSize(of: image)
        let maxDim = max(imageSize.width, imageSize.height)
        if maxDim > maxDimension {
            let scale = maxDimension / maxDim
            let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
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
        let imageSize = pixelSize(of: image)
        let maxDim = max(imageSize.width, imageSize.height)
        if maxDim > maxDimension {
            let scale = maxDimension / maxDim
            let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
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

        // Step 3: Reduce dimensions if quality compression is still too large.
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
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        guard let cgImage = image.cgImage else {
            return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        let raw = CGSize(width: cgImage.width, height: cgImage.height)
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: raw.height, height: raw.width)
        default:
            return raw
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
