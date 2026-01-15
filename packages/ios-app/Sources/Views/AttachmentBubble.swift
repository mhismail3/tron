import SwiftUI

/// Compact bubble for displaying attachment previews above the input bar
/// Sized to fit 2 attachments per row
struct AttachmentBubble: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            // Thumbnail or icon
            thumbnailView

            // File info
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(attachment.formattedSize)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 60, alignment: .leading)

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
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
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                // Icon for non-image attachments
                iconView
            }
        }
    }

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(iconBackgroundColor)
                .frame(width: 28, height: 28)

            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
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
