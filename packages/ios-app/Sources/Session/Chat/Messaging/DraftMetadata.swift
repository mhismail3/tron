import Foundation

// MARK: - Draft Attachment Metadata

/// Codable metadata for a draft attachment, excluding binary data.
/// Used for SQLite persistence — the actual file data is stored on disk.
struct DraftAttachmentMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let type: AttachmentType
    let mimeType: String
    let fileName: String?
    let originalSize: Int
    let wasConverted: Bool
    let originalMimeType: String?
}
