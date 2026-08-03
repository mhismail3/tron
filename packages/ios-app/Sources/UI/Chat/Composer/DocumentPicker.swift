import SwiftUI
import UniformTypeIdentifiers

/// UIViewControllerRepresentable wrapper for UIDocumentPickerViewController
struct DocumentPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let tool: AttachmentSupport
    let onDocumentPicked: (Data, String, String?) -> Void  // data, mimeType, fileName
    let onSizeExceeded: ((Int, Int) -> Void)?  // actualSize, maxSize

    init(
        tool: AttachmentSupport = .default,
        onDocumentPicked: @escaping (Data, String, String?) -> Void,
        onSizeExceeded: ((Int, Int) -> Void)? = nil
    ) {
        self.tool = tool
        self.onDocumentPicked = onDocumentPicked
        self.onSizeExceeded = onSizeExceeded
    }

    /// Supported document types filtered by provider tool.
    static func supportedTypes(for tool: AttachmentSupport) -> [UTType] {
        var types: [UTType] = [.plainText, .json]  // always supported via text extraction
        if tool.supportsPdfContent { types.append(.pdf) }
        if tool.supportsImages {
            types += [.image, .png, .jpeg, .gif, .webP]
        }
        return types
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = Self.supportedTypes(for: tool)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
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

            // Read while the security-scoped resource is active. Images use a
            // generous source bound because they are compressed after pickup;
            // documents must already fit the model policy.
            let mimeType = mimeTypeForURL(url)
            let isImage = mimeType.hasPrefix("image/")
            let maxBytes = isImage ? ImageProcessor.maximumSourceBytes : parent.tool.maxDocumentBytes
            if maxBytes > 0, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? Int, fileSize > maxBytes {
                parent.onSizeExceeded?(fileSize, maxBytes)
                parent.dismiss()
                return
            }

            let fileName = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                parent.dismiss()
                return
            }
            parent.onDocumentPicked(data, mimeType, fileName)
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
