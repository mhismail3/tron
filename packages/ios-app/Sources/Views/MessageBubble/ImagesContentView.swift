import SwiftUI

// MARK: - Images Content View (Terminal-style)

struct ImagesContentView: View {
    let images: [ImageContent]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.tronBorder.opacity(0.5), lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(4)
    }
}

// MARK: - Attached File Thumbnails (displayed above user message text)

struct AttachedFileThumbnails: View {
    let attachments: [Attachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment)
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
            if attachment.isImage, let uiImage = UIImage(data: attachment.data) {
                // Image thumbnail
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
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
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(attachment.formattedSize)
                        .font(TronTypography.sans(size: TronTypography.sizeXXS))
                        .foregroundStyle(.white.opacity(0.5))
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
