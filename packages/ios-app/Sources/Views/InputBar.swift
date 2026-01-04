import SwiftUI
import PhotosUI

// MARK: - Input Bar

struct InputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    @Binding var attachedImages: [ImageContent]
    @Binding var selectedImages: [PhotosPickerItem]
    let onSend: () -> Void
    let onAbort: () -> Void
    let onRemoveImage: (ImageContent) -> Void

    @FocusState private var isFocused: Bool
    @State private var showingImagePicker = false

    var body: some View {
        VStack(spacing: 8) {
            // Attached images preview
            if !attachedImages.isEmpty {
                attachedImagesRow
            }

            // Input row
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button
                attachmentMenu

                // Text field
                textField

                // Send/Abort button
                actionButton
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.tronSurface)
        .overlay(
            Rectangle()
                .fill(Color.tronBorder)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Attached Images Row

    private var attachedImagesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { image in
                    AttachedImageThumbnail(
                        image: image,
                        onRemove: { onRemoveImage(image) }
                    )
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 70)
    }

    // MARK: - Attachment Menu

    private var attachmentMenu: some View {
        Menu {
            PhotosPicker(
                selection: $selectedImages,
                maxSelectionCount: 5,
                matching: .images
            ) {
                Label("Photo Library", systemImage: TronIcon.photo.systemName)
            }

            Button {
                // Camera would go here - requires additional permissions
            } label: {
                Label("Camera", systemImage: TronIcon.camera.systemName)
            }
            .disabled(true) // Camera not implemented yet
        } label: {
            TronIconView(icon: .attach, size: 22, color: .tronTextSecondary)
                .frame(width: 36, height: 36)
        }
        .disabled(isProcessing)
    }

    // MARK: - Text Field

    private var textField: some View {
        TextField("Message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(.tronTextPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.tronBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.tronBorder, lineWidth: 1)
            )
            .lineLimit(1...8)
            .focused($isFocused)
            .disabled(isProcessing)
            .onSubmit {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSend()
                }
            }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            if isProcessing {
                onAbort()
            } else {
                onSend()
            }
        } label: {
            Group {
                if isProcessing {
                    TronIconView(icon: .abort, size: 32, color: .tronError)
                } else {
                    TronIconView(
                        icon: .send,
                        size: 32,
                        color: canSend ? .tronEmerald : .tronTextDisabled
                    )
                }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(!isProcessing && !canSend)
        .animation(.tronFast, value: isProcessing)
        .animation(.tronFast, value: canSend)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }
}

// MARK: - Attached Image Thumbnail

struct AttachedImageThumbnail: View {
    let image: ImageContent
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.tronSurfaceElevated)
                    .frame(width: 60, height: 60)
                    .overlay {
                        TronIconView(icon: .photo, size: 24, color: .tronTextMuted)
                    }
            }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 16, height: 16)
                    )
            }
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        InputBar(
            text: .constant("Hello world"),
            isProcessing: false,
            attachedImages: .constant([]),
            selectedImages: .constant([]),
            onSend: {},
            onAbort: {},
            onRemoveImage: { _ in }
        )
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
