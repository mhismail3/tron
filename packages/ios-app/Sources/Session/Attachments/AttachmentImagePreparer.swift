import Foundation

/// Canonical image-to-attachment boundary shared by camera, Photos, and Files.
/// The server catalog owns limits; this type only performs the required local
/// transform and preserves source metadata for the timeline.
struct AttachmentImagePreparer {
    static func prepare(
        data: Data,
        declaredMimeType: String? = nil,
        fileName: String? = nil,
        limits: ProviderImageLimits
    ) async -> Attachment? {
        let detectedMimeType = ImageProcessor.detectMimeType(from: data)
        let sourceMimeType = declaredMimeType.flatMap { declared in
            declared.hasPrefix("image/") ? declared : nil
        } ?? detectedMimeType

        guard let result = await ImageProcessor.process(
            originalData: data,
            mimeType: sourceMimeType,
            limits: limits
        ) else {
            return nil
        }

        return Attachment(
            type: .image,
            data: result.data,
            mimeType: result.mimeType,
            fileName: fileName,
            originalSize: data.count,
            wasConverted: result.wasConverted,
            originalMimeType: result.wasConverted ? sourceMimeType : nil
        )
    }
}
