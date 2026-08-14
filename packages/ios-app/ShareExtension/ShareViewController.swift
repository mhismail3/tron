import UIKit
import UniformTypeIdentifiers

@MainActor
protocol ShareAppOpening {
    func openShareApp(from responder: UIResponder)
}

struct ResponderChainShareAppOpener: ShareAppOpening {
    func openShareApp(from responder: UIResponder) {
        guard let url = URL(string: "tron://share") else { return }
        var current: UIResponder? = responder
        while let next = current?.next {
            if let application = next as? UIApplication {
                application.open(url)
                return
            }
            current = next
        }
    }
}

final class ShareViewController: UIViewController {
    private let pendingShares: any PendingShareStoring
    private let appOpener: any ShareAppOpening

    init(
        pendingShares: any PendingShareStoring,
        appOpener: any ShareAppOpening
    ) {
        self.pendingShares = pendingShares
        self.appOpener = appOpener
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        pendingShares = UserDefaultsPendingShareStore()
        appOpener = ResponderChainShareAppOpener()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        pendingShares = UserDefaultsPendingShareStore()
        appOpener = ResponderChainShareAppOpener()
        super.init(coder: coder)
    }

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
            var fragments: [SharedContentFragment] = []
            for provider in providers {
                if let fragment = await extractContent(from: provider) {
                    fragments.append(fragment)
                }
            }
            guard let content = SharedContentReducer.content(
                from: fragments,
                timestamp: Date()
            ) else {
                complete()
                return
            }

            pendingShares.save(content)
            appOpener.openShareApp(from: self)
            complete()
        }
    }

    // MARK: - Content Extraction

    private func extractContent(from provider: NSItemProvider) async -> SharedContentFragment? {
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

    // MARK: - Completion

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
