import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        processSharedItems()
    }

    // MARK: - Item Processing

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            complete()
            return
        }

        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            complete()
            return
        }

        Task {
            var text: String?
            var url: String?

            for provider in providers {
                if let result = await extractContent(from: provider) {
                    switch result {
                    case .text(let t):
                        text = t
                    case .url(let u):
                        // If we already have a URL, append to text instead
                        if url != nil {
                            text = [text, u].compactMap { $0 }.joined(separator: "\n")
                        } else {
                            url = u
                        }
                    }
                }
            }

            guard text != nil || url != nil else {
                complete()
                return
            }

            let content = SharedContent(text: text, url: url, timestamp: Date())
            PendingShareService.save(content)
            openMainApp()
            complete()
        }
    }

    // MARK: - Content Extraction

    private enum ExtractedContent {
        case text(String)
        case url(String)
    }

    private func extractContent(from provider: NSItemProvider) async -> ExtractedContent? {
        // Try URL first (more specific than plain text)
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(from: provider) {
                return .url(url)
            }
        }

        // Then try plain text
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(from: provider) {
                return .text(text)
            }
        }

        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - App Launch

    /// Open the main app via the responder chain's openURL method.
    private func openMainApp() {
        guard let url = URL(string: "tron://share") else { return }
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let application = next as? UIApplication {
                application.open(url)
                return
            }
            responder = next
        }
    }

    // MARK: - Completion

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
