import SwiftUI
import UniformTypeIdentifiers

/// UIViewControllerRepresentable wrapper for UIDocumentPickerViewController
struct DocumentPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onDocumentPicked: (URL, String, String?) -> Void  // URL, mimeType, fileName

    /// Supported document types
    static let supportedTypes: [UTType] = [
        .pdf,
        .image,
        .png,
        .jpeg,
        .gif,
        .webP,
        .plainText,
        .json
    ]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.supportedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.dismiss()
                return
            }

            // Start security-scoped access
            guard url.startAccessingSecurityScopedResource() else {
                parent.dismiss()
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            // Determine MIME type from UTI
            let mimeType = mimeTypeForURL(url)
            let fileName = url.lastPathComponent

            parent.onDocumentPicked(url, mimeType, fileName)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }

        private func mimeTypeForURL(_ url: URL) -> String {
            let pathExtension = url.pathExtension.lowercased()

            switch pathExtension {
            case "pdf":
                return "application/pdf"
            case "jpg", "jpeg":
                return "image/jpeg"
            case "png":
                return "image/png"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "txt":
                return "text/plain"
            case "json":
                return "application/json"
            default:
                // Try to get UTI-based MIME type
                if let utType = UTType(filenameExtension: pathExtension),
                   let mimeType = utType.preferredMIMEType {
                    return mimeType
                }
                return "application/octet-stream"
            }
        }
    }
}
