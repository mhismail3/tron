import Foundation

/// Effective image processing limits received from the server model catalog.
struct ProviderImageLimits: Equatable {
    /// Maximum dimension in pixels (longest edge).
    let maxDimension: CGFloat
    /// Maximum file size in bytes.
    let maxBytes: Int
    /// MIME types the provider accepts.
    let supportedFormats: Set<String>

    init(policy: ModelAttachmentPolicy) {
        maxDimension = CGFloat(policy.maxImageDimension)
        maxBytes = policy.maxImageBytes
        supportedFormats = Set(policy.supportedImageMimeTypes)
    }

    init(maxDimension: CGFloat, maxBytes: Int, supportedFormats: Set<String>) {
        self.maxDimension = maxDimension
        self.maxBytes = maxBytes
        self.supportedFormats = supportedFormats
    }

    /// Conservative construction value before the first model catalog read.
    static let `default` = ProviderImageLimits(
        maxDimension: 1_568,
        maxBytes: 1_400_000,
        supportedFormats: ["image/jpeg", "image/png", "image/gif", "image/webp"]
    )
}

/// Describes what attachment types a model/provider supports.
struct AttachmentCapability: Equatable {
    /// Whether the model supports image inputs (vision).
    let supportsImages: Bool
    /// Whether the model can read PDF binary content natively (Anthropic, Gemini).
    let supportsPdfContent: Bool
    /// Whether text files can be sent (always true — agent extracts text inline).
    let supportsTextFiles: Bool
    /// Maximum image file size in bytes.
    let maxImageBytes: Int
    /// Maximum document file size in bytes.
    let maxDocumentBytes: Int

    /// Derive capability from the server-owned model attachment policy.
    static func from(model: ModelInfo?) -> AttachmentCapability {
        guard let model = model else { return .default }
        let policy = model.attachmentPolicy
        return AttachmentCapability(
            supportsImages: model.supportsImages && policy.maxImageBytes > 0,
            supportsPdfContent: policy.supportsPdfContent,
            supportsTextFiles: policy.supportsTextFiles,
            maxImageBytes: policy.maxImageBytes,
            maxDocumentBytes: policy.maxDocumentBytes
        )
    }

    static let `default` = AttachmentCapability(
        supportsImages: true,
        supportsPdfContent: true,
        supportsTextFiles: true,
        maxImageBytes: 1_400_000,
        maxDocumentBytes: 20_971_520
    )
}
