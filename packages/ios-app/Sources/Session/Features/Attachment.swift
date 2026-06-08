import Foundation

// MARK: - Attachment Type

/// Type of attachment based on MIME type
enum AttachmentType: String, Codable, Equatable, Sendable {
    case image
    case pdf
    case document

    /// Determine attachment type from MIME type
    static func from(mimeType: String) -> AttachmentType {
        if mimeType.hasPrefix("image/") {
            return .image
        }
        if mimeType == "application/pdf" {
            return .pdf
        }
        return .document
    }
}

// MARK: - Attachment

/// Unified attachment model for images, PDFs, and documents
struct Attachment: Identifiable, Equatable {
    let id: UUID
    let type: AttachmentType
    let data: Data
    let mimeType: String
    let fileName: String?
    let originalSize: Int
    /// Whether the image was converted from its original format (e.g., GIF → JPEG).
    let wasConverted: Bool
    /// The original MIME type before conversion, if conversion occurred.
    let originalMimeType: String?

    // MARK: - Computed Properties

    /// Display name for the attachment
    var displayName: String {
        if let name = fileName {
            return name
        }
        switch type {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .document: return "Document"
        }
    }

    /// Whether this is an image attachment
    var isImage: Bool { type == .image }

    /// Whether this is a PDF attachment
    var isPDF: Bool { type == .pdf }

    /// Whether this is a document attachment (non-image, non-PDF)
    var isDocument: Bool { type == .document }

    /// Formatted file size for display
    var formattedSize: String {
        let bytes = data.count
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return "\(bytes / 1024) KB"
        } else {
            let mb = Double(bytes) / (1024 * 1024)
            return String(format: "%.1f MB", mb)
        }
    }

    // MARK: - Initializers

    /// Primary initializer with all parameters
    init(
        id: UUID = UUID(),
        type: AttachmentType,
        data: Data,
        mimeType: String,
        fileName: String?,
        originalSize: Int? = nil,
        wasConverted: Bool = false,
        originalMimeType: String? = nil
    ) {
        self.id = id
        self.type = type
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.originalSize = originalSize ?? data.count
        self.wasConverted = wasConverted
        self.originalMimeType = originalMimeType
    }

    /// Convenience initializer that auto-detects type from MIME
    static func from(
        data: Data,
        mimeType: String,
        fileName: String? = nil,
        originalSize: Int? = nil,
        wasConverted: Bool = false,
        originalMimeType: String? = nil
    ) -> Attachment {
        return Attachment(
            type: AttachmentType.from(mimeType: mimeType),
            data: data,
            mimeType: mimeType,
            fileName: fileName,
            originalSize: originalSize,
            wasConverted: wasConverted,
            originalMimeType: originalMimeType
        )
    }

    // MARK: - Equatable

    /// Whether this attachment is compatible with the given capability.
    func isCompatible(with capability: AttachmentCapability) -> Bool {
        switch type {
        case .image: return capability.supportsImages
        case .pdf: return capability.supportsPdfContent
        case .document: return true // text files always supported via extraction
        }
    }

    /// Subtle warning text when content won't be fully readable.
    func warningText(for capability: AttachmentCapability) -> String? {
        if type == .pdf && !capability.supportsPdfContent {
            return "PDF content not readable by this model"
        }
        return nil
    }

    static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        return lhs.id == rhs.id &&
            lhs.type == rhs.type &&
            lhs.data == rhs.data &&
            lhs.mimeType == rhs.mimeType &&
            lhs.fileName == rhs.fileName &&
            lhs.originalSize == rhs.originalSize
    }
}

// MARK: - Supported MIME Types

extension Attachment {
    /// Supported image MIME types
    static let supportedImageTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp"
    ]

    /// Supported document MIME types
    static let supportedDocumentTypes: Set<String> = [
        "application/pdf"
    ]

    /// Check if a MIME type is supported for attachments
    static func isSupportedMimeType(_ mimeType: String) -> Bool {
        return supportedImageTypes.contains(mimeType) ||
            supportedDocumentTypes.contains(mimeType) ||
            mimeType.hasPrefix("text/")
    }
}
