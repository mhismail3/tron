import SwiftUI
import UIKit

enum ChatAttachmentDestination: Hashable {
    case camera
    case photos
    case files
}

enum ChatAttachmentImportPolicy {
    static let maximumPhotoSelection = 5
    static let maximumFileSelection = 10
}

struct ComposerAttachmentMenuButton: UIViewRepresentable {
    let isEnabled: Bool
    let onSelect: @MainActor (ChatAttachmentDestination) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.isAccessibilityElement = true
        button.accessibilityLabel = "Add attachment"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        button.menu = context.coordinator.makeMenu()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ComposerAttachmentMenuButton

        init(parent: ComposerAttachmentMenuButton) {
            self.parent = parent
        }

        func makeMenu() -> UIMenu {
            UIMenu(children: [
                action("Take Photo", systemImage: "camera", destination: .camera),
                action("Select Photos", systemImage: "photo.on.rectangle", destination: .photos),
                action("Attach Files", systemImage: "folder", destination: .files),
            ])
        }

        private func action(
            _ title: String,
            systemImage: String,
            destination: ChatAttachmentDestination
        ) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: systemImage)) { [weak self] _ in
                self?.parent.onSelect(destination)
            }
        }
    }
}

enum PendingPhotoRemoveLayoutPolicy {
    static let previewSide: CGFloat = 64
    static let visibleDiameter: CGFloat = 22
    static let touchTarget: CGFloat = 30

    /// A top-trailing overlay aligns by its frame edge. Moving it by half its
    /// target size places the control's center exactly on the preview corner.
    static var centerOnTopTrailingCornerOffset: CGSize {
        CGSize(width: touchTarget / 2, height: -touchTarget / 2)
    }
}

struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void
    @State private var showPreview = false

    var body: some View {
        Group {
            if attachment.mimeType.hasPrefix("image/") {
                imagePreview
            } else {
                fileChip
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
    }

    private var imagePreview: some View {
        imageBase
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    ZStack {
                        Circle()
                            .fill(Color.tronBackground.opacity(0.92))
                        Circle()
                            .stroke(Color.tronTextMuted.opacity(0.35), lineWidth: 0.5)
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeCaption,
                                weight: .bold
                            ))
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    .frame(
                        width: PendingPhotoRemoveLayoutPolicy.visibleDiameter,
                        height: PendingPhotoRemoveLayoutPolicy.visibleDiameter
                    )
                    .frame(
                        width: PendingPhotoRemoveLayoutPolicy.touchTarget,
                        height: PendingPhotoRemoveLayoutPolicy.touchTarget
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
                .offset(
                    x: PendingPhotoRemoveLayoutPolicy.centerOnTopTrailingCornerOffset.width,
                    y: PendingPhotoRemoveLayoutPolicy.centerOnTopTrailingCornerOffset.height
                )
            }
            .sheet(isPresented: $showPreview) {
                if let image = decodedPreviewImage {
                    AttachmentImagePreviewSheet(image: image)
                }
            }
    }

    private var imageBase: some View {
        ZStack {
            if let image = decodedPreviewImage {
                Button { showPreview = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: PendingPhotoRemoveLayoutPolicy.previewSide,
                            height: PendingPhotoRemoveLayoutPolicy.previewSide
                        )
                        .clipped()
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                // Plain button semantics plus noninteractive glass keep a tap
                // from pulsing or morphing the staged photo.
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(attachment.name)")
                .accessibilityHint("Opens a photo preview")
            } else {
                Image(systemName: "photo.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(Color.tronBlue)
                    .accessibilityLabel("Attached \(attachment.name)")
            }
        }
        .frame(
            width: PendingPhotoRemoveLayoutPolicy.previewSide,
            height: PendingPhotoRemoveLayoutPolicy.previewSide
        )
        .glassEffect(
            .regular.tint(Color.tronBlue.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var decodedPreviewImage: UIImage? {
        attachment.previewData.flatMap(UIImage.init(data:))
    }

    private var fileChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.fill").foregroundStyle(Color.tronBlue)
            Text(attachment.name)
                .font(TronTypography.code(size: TronTypography.sizeBody2))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 100)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.tronTextMuted)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .font(TronTypography.caption)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(Color.tronBlue.opacity(0.22)).interactive(), in: Capsule())
    }
}
