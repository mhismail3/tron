import SwiftUI
import PhotosUI

// MARK: - Attachment Menu Action

enum AttachmentMenuAction: String, CaseIterable, Identifiable, Equatable {
    case camera
    case photoLibrary
    case files

    var id: String { rawValue }

    static func availableActions(for capability: AttachmentCapability) -> [AttachmentMenuAction] {
        var actions: [AttachmentMenuAction] = []
        if capability.supportsImages {
            actions += [.camera, .photoLibrary]
        }
        actions.append(.files)
        return actions
    }

    var title: String {
        switch self {
        case .camera:
            return "Take Photo"
        case .photoLibrary:
            return "Photo Library"
        case .files:
            return "Choose File"
        }
    }

    var systemImage: String {
        switch self {
        case .camera:
            return "camera"
        case .photoLibrary:
            return "photo.on.rectangle"
        case .files:
            return "folder"
        }
    }
}

// MARK: - Attachment Menu Sheet

struct AttachmentMenuSheet: View {
    let capability: AttachmentCapability
    @Binding var selectedImages: [PhotosPickerItem]
    let onCameraImageCaptured: (UIImage) -> Void
    let onDocumentPicked: (URL, String, String?) -> Void
    let onDocumentSizeExceeded: ((Int, Int) -> Void)?

    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var showingImagePicker = false

    private var actions: [AttachmentMenuAction] {
        AttachmentMenuAction.availableActions(for: capability)
    }

    var body: some View {
        NavigationStack {
            LazyVGrid(
                columns: CompactActionSheetLayout.columns(forItemCount: actions.count),
                spacing: CompactActionSheetLayout.rowSpacing
            ) {
                ForEach(actions) { action in
                    CompactActionSheetButton(
                        title: action.title,
                        systemImage: action.systemImage,
                        accent: .tronEmerald
                    ) {
                        present(action)
                    }
                }
            }
            .padding(.horizontal, CompactActionSheetLayout.horizontalPadding)
            .padding(.vertical, CompactActionSheetLayout.verticalPadding)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Add Attachment", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .compactHeightSheetPresentation(height: CompactActionSheetLayout.sheetHeight(forItemCount: actions.count))
        .tint(.tronEmerald)
        .sheet(isPresented: $showCamera) {
            CameraCaptureSheet(onImageCaptured: onCameraImageCaptured)
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(
                capability: capability,
                onDocumentPicked: onDocumentPicked,
                onSizeExceeded: onDocumentSizeExceeded
            )
        }
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $selectedImages,
            maxSelectionCount: 5,
            matching: .images
        )
    }

    private func present(_ action: AttachmentMenuAction) {
        switch action {
        case .camera:
            showCamera = true
        case .photoLibrary:
            showingImagePicker = true
        case .files:
            showFilePicker = true
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var selectedImages: [PhotosPickerItem] = []

    AttachmentMenuSheet(
        capability: .default,
        selectedImages: $selectedImages,
        onCameraImageCaptured: { _ in },
        onDocumentPicked: { _, _, _ in },
        onDocumentSizeExceeded: nil
    )
}
#endif
