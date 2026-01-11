import SwiftUI

/// Compact bubble for displaying attachment previews above the input bar
struct AttachmentBubble: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Thumbnail or icon
            thumbnailView

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if attachment.isImage, let uiImage = UIImage(data: attachment.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Icon for non-image attachments
                iconView
            }
        }
    }

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(iconBackgroundColor)
                .frame(width: 36, height: 36)

            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconForegroundColor)
        }
    }

    private var iconName: String {
        switch attachment.type {
        case .pdf:
            return "doc.fill"
        case .document:
            return "doc.text.fill"
        case .image:
            return "photo.fill"
        }
    }

    private var iconBackgroundColor: Color {
        switch attachment.type {
        case .pdf:
            return .red.opacity(0.15)
        case .document:
            return .blue.opacity(0.15)
        case .image:
            return .green.opacity(0.15)
        }
    }

    private var iconForegroundColor: Color {
        switch attachment.type {
        case .pdf:
            return .red
        case .document:
            return .blue
        case .image:
            return .green
        }
    }
}
