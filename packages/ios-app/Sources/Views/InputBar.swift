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
    var inputHistory: InputHistoryStore?
    var onHistoryNavigate: ((String) -> Void)?

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
        VStack(spacing: 4) {
            // History indicator
            if let history = inputHistory, history.isNavigating,
               let position = history.navigationPosition {
                Text("History: \(position)")
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                // History navigation buttons
                if inputHistory != nil {
                    historyNavigationButtons
                }

                TextField("Message...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .disabled(isProcessing)
                    .onSubmit {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSend()
                        }
                    }
            }
        }
    }

    // MARK: - History Navigation

    private var historyNavigationButtons: some View {
        VStack(spacing: 2) {
            Button {
                navigateHistoryUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 24, height: 16)
            }
            .disabled(isProcessing || inputHistory?.history.isEmpty == true)

            Button {
                navigateHistoryDown()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 24, height: 16)
            }
            .disabled(isProcessing || inputHistory?.isNavigating != true)
        }
    }

    private func navigateHistoryUp() {
        guard let history = inputHistory else { return }
        if let newText = history.navigateUp(currentInput: text) {
            onHistoryNavigate?(newText)
        }
    }

    private func navigateHistoryDown() {
        guard let history = inputHistory else { return }
        if let newText = history.navigateDown() {
            onHistoryNavigate?(newText)
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
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.tronSurfaceElevated)
                    .frame(width: 56, height: 56)
                    .overlay {
                        TronIconView(icon: .photo, size: 20, color: .tronTextMuted)
                    }
            }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 4, y: -4)
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
            onRemoveImage: { _ in },
            inputHistory: nil,
            onHistoryNavigate: nil
        )
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
