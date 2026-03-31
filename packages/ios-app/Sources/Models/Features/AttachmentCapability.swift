import Foundation

/// Provider-specific image processing limits.
struct ProviderImageLimits: Equatable {
    /// Maximum dimension in pixels (longest edge).
    let maxDimension: CGFloat
    /// Maximum file size in bytes.
    let maxBytes: Int
    /// MIME types the provider accepts.
    let supportedFormats: Set<String>

    static let anthropic = ProviderImageLimits(
        maxDimension: 1568,
        maxBytes: 5_242_880,
        supportedFormats: ["image/jpeg", "image/png", "image/gif", "image/webp"]
    )
    static let openai = ProviderImageLimits(
        maxDimension: 2048,
        maxBytes: 20_971_520,
        supportedFormats: ["image/jpeg", "image/png", "image/webp"]
    )
    static let gemini = ProviderImageLimits(
        maxDimension: 3072,
        maxBytes: 5_242_880,
        supportedFormats: ["image/jpeg", "image/png", "image/gif", "image/webp"]
    )
    static let kimi = ProviderImageLimits(
        maxDimension: 4096,
        maxBytes: 10_485_760,
        supportedFormats: ["image/jpeg", "image/png", "image/gif", "image/webp"]
    )
    static let `default` = ProviderImageLimits(
        maxDimension: 1568,
        maxBytes: 5_242_880,
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

    /// Derive capability from model info. Falls back to permissive defaults.
    static func from(model: ModelInfo?) -> AttachmentCapability {
        guard let model = model else { return .default }

        if model.isAnthropic {
            return AttachmentCapability(
                supportsImages: true,
                supportsPdfContent: true,
                supportsTextFiles: true,
                maxImageBytes: 5_242_880,
                maxDocumentBytes: 20_971_520
            )
        }
        if model.isCodex {
            return AttachmentCapability(
                supportsImages: model.supportsImages ?? true,
                supportsPdfContent: false,
                supportsTextFiles: true,
                maxImageBytes: 20_971_520,
                maxDocumentBytes: 52_428_800
            )
        }
        if model.isGemini {
            return AttachmentCapability(
                supportsImages: true,
                supportsPdfContent: true,
                supportsTextFiles: true,
                maxImageBytes: 5_242_880,
                maxDocumentBytes: 20_971_520
            )
        }
        if model.isKimi {
            return AttachmentCapability(
                supportsImages: model.supportsImages ?? false,
                supportsPdfContent: false,
                supportsTextFiles: true,
                maxImageBytes: 10_485_760,
                maxDocumentBytes: 104_857_600
            )
        }
        if model.isMiniMax {
            return AttachmentCapability(
                supportsImages: false,
                supportsPdfContent: false,
                supportsTextFiles: true,
                maxImageBytes: 0,
                maxDocumentBytes: 0
            )
        }
        return .default
    }

    static let `default` = AttachmentCapability(
        supportsImages: true,
        supportsPdfContent: true,
        supportsTextFiles: true,
        maxImageBytes: 5_242_880,
        maxDocumentBytes: 20_971_520
    )
}
