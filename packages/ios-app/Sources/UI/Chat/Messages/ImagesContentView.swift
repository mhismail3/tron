import SwiftUI

// MARK: - Images Content View (Terminal-style)

struct ImagesContentView: View {
    let images: [ImageContent]
    var onPreview: ((ChatImagePreviewData) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                if let onPreview {
                    Button {
                        onPreview(ChatImagePreviewData(image: image))
                    } label: {
                        imageThumbnail(image)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityLabel("Preview photo")
                    .accessibilityHint("Opens an expanded, zoomable preview")
                } else {
                    imageThumbnail(image)
                }
            }
        }
        .padding(4)
    }

    private func imageThumbnail(_ image: ImageContent) -> some View {
        DecodedImageView(data: image.data, size: CGSize(width: 72, height: 72))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.tronBorder.opacity(0.5), lineWidth: 0.5)
            )
    }
}

// MARK: - Attached File Thumbnails (displayed above user message text)

struct AttachedFileThumbnails: View {
    let attachments: [Attachment]
    var onPreview: ((ChatImagePreviewData) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                if attachment.isImage, let onPreview {
                    Button {
                        onPreview(ChatImagePreviewData(attachment: attachment))
                    } label: {
                        AttachmentThumbnail(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Preview \(attachment.displayName)")
                    .accessibilityHint("Opens an expanded, zoomable preview")
                } else {
                    AttachmentThumbnail(attachment: attachment)
                }
            }
        }
    }
}

// MARK: - Individual Attachment Thumbnail

/// Individual attachment thumbnail for display in chat messages
struct AttachmentThumbnail: View {
    let attachment: Attachment

    var body: some View {
        Group {
            if attachment.isImage {
                DecodedImageView(data: attachment.data, size: CGSize(width: 56, height: 56))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 1)
                    )
            } else {
                // Document/PDF thumbnail with icon
                VStack(spacing: 2) {
                    Image(systemName: attachment.isPDF ? "doc.fill" : "doc.text.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronEmerald)

                    if let fileName = attachment.fileName {
                        Text(fileName)
                            .font(TronTypography.labelSM)
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(attachment.formattedSize)
                        .font(TronTypography.sans(size: TronTypography.sizeXXS))
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(width: 56, height: 56)
                .background(Color.tronSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
}
