import SwiftUI
import UIKit

enum ChatAttachmentDestination: Hashable {
    case camera
    case photos
    case files
}

enum ChatAttachmentImportPolicy {
    static let maximumPhotoSelection = 5
    static let maximumFileSelection = ComposerAttachmentPolicy.maximumCount
    static let maximumFileBytes = ComposerAttachmentPolicy.maximumTotalBytes
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
            let image = UIImage(systemName: systemImage)?.withTintColor(
                UIColor(Color.tronEmerald),
                renderingMode: .alwaysOriginal
            )
            return UIAction(title: title, image: image) { [weak self] _ in
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

struct AttachmentThumbnailSurface: View {
    let image: UIImage?
    let name: String
    let mimeType: String

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: fallbackIcon)
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                        .foregroundStyle(Color.tronBlue)
                    Text(name)
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                }
            }
        }
        .frame(
            width: PendingPhotoRemoveLayoutPolicy.previewSide,
            height: PendingPhotoRemoveLayoutPolicy.previewSide
        )
        .clipped()
        .glassEffect(
            .regular.tint(Color.tronBlue.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fallbackIcon: String {
        if mimeType.hasPrefix("image/") { return "photo.fill" }
        if mimeType == "application/pdf" { return "doc.richtext.fill" }
        return "doc.text.fill"
    }
}

struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model
    @State private var showPreview = false

    var body: some View {
        previewBase
            .overlay(alignment: .topTrailing) { removeButton }
            .sheet(isPresented: $showPreview) { previewSheet }
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
    }

    @ViewBuilder
    private var previewBase: some View {
        if let decodedPreviewImage {
            Button { showPreview = true } label: {
                AttachmentThumbnailSurface(
                    image: decodedPreviewImage,
                    name: attachment.name,
                    mimeType: attachment.mimeType
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(attachment.name)")
            .accessibilityHint(attachment.mimeType.hasPrefix("image/") ? "Opens a photo preview" : "Opens the file preview")
        } else {
            AttachmentThumbnailSurface(
                image: nil,
                name: attachment.name,
                mimeType: attachment.mimeType
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(attachment.mimeType.hasPrefix("image/")
                ? "Attached photo \(attachment.name)"
                : "Attached file \(attachment.name)")
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            ZStack {
                Circle().fill(Color.tronBackground.opacity(0.92))
                Circle().stroke(Color.tronTextMuted.opacity(0.35), lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
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

    @ViewBuilder
    private var previewSheet: some View {
        if let thumbnail = decodedPreviewImage,
           let fullPreviewData = attachment.fullPreviewData {
            PendingAttachmentImagePreviewSheet(
                thumbnail: thumbnail,
                fullPreviewData: fullPreviewData,
                prepareFullPreview: model.chatMedia.prepareLocalFullPreview
            )
        } else if let decodedPreviewImage {
            AttachmentImagePreviewSheet(image: decodedPreviewImage, title: attachment.name)
        }
    }

    private var decodedPreviewImage: UIImage? {
        attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) }
    }
}

private struct PendingAttachmentImagePreviewSheet: View {
    let fullPreviewData: Data
    let prepareFullPreview: @MainActor (Data) async throws -> UIImage
    @State private var image: UIImage

    init(
        thumbnail: UIImage,
        fullPreviewData: Data,
        prepareFullPreview: @escaping @MainActor (Data) async throws -> UIImage
    ) {
        self.fullPreviewData = fullPreviewData
        self.prepareFullPreview = prepareFullPreview
        _image = State(initialValue: thumbnail)
    }

    var body: some View {
        AttachmentImagePreviewSheet(image: image)
            .task {
                guard let prepared = try? await prepareFullPreview(fullPreviewData),
                      !Task.isCancelled else { return }
                image = prepared
            }
    }
}
