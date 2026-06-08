import SwiftUI
import UIKit

/// Compact chip for displaying staged attachments above the input bar.
struct AttachmentBubble: View {
    let attachment: Attachment
    let capability: AttachmentCapability
    let onRemove: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let fileNameMaxWidth: CGFloat = 76
    private var tint: TintedColors { TintedColors(accent: .tronSlate, colorScheme: colorScheme) }
    private var warning: String? { attachment.warningText(for: capability) }
    private var fileNameWidth: CGFloat {
        let font = TronTypography.uiFont(mono: false, size: TronTypography.sizeBody2, weight: .medium)
        let width = (attachment.displayName as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return min(max(width, 1), fileNameMaxWidth)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            Text(attachment.displayName)
                .font(TronTypography.filePath)
                .foregroundStyle(tint.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: fileNameWidth, alignment: .leading)

            Text(attachment.formattedSize)
                .font(TronTypography.pill)
                .foregroundStyle(sizeColor)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.dismiss)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel(removeAccessibilityLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .chipStyleMaterial(tint.accent, tintOpacity: 0.32)
        .contentShape(Capsule())
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

    private var iconColor: Color {
        if warning != nil {
            return .tronAmber
        }
        return tint.accent
    }

    private var sizeColor: Color {
        if warning != nil {
            return .tronAmber.opacity(0.85)
        }
        return tint.secondary
    }

    private var removeAccessibilityLabel: String {
        var label = "Remove attachment, \(attachment.displayName), \(attachment.formattedSize)"
        if let warning {
            label += ", \(warning)"
        }
        return label
    }
}
