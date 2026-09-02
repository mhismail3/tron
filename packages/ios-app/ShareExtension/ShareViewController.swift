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
    private enum ExtractionResult {
        case fragment(SharedContentFragment)
        case unavailable
        case rejected
    }

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
        guard !providers.isEmpty,
              providers.count <= SharedContentAdmissionPolicy.maximumProviderCount else {
            complete()
            return
        }

        Task {
            var fragments: [SharedContentFragment] = []
            for provider in providers {
                switch await extractContent(from: provider) {
                case .fragment(let fragment):
                    fragments.append(fragment)
                    guard SharedContentAdmissionPolicy.admits(fragments) else {
                        complete()
                        return
                    }
                case .unavailable:
                    continue
                case .rejected:
                    complete()
                    return
                }
            }
            guard let content = SharedContentReducer.content(
                from: fragments,
                timestamp: Date()
            ), pendingShares.save(content) else {
                complete()
                return
            }

            appOpener.openShareApp(from: self)
            complete()
        }
    }

    // MARK: - Content Extraction

    private func extractContent(from provider: NSItemProvider) async -> ExtractionResult {
        // Try URL first (more specific than plain text)
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(from: provider) {
            let fragment = SharedContentFragment.url(url)
            return SharedContentAdmissionPolicy.admits(fragment) ? .fragment(fragment) : .rejected
        }

        // Then try plain text
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(from: provider) {
            let fragment = SharedContentFragment.text(text)
            return SharedContentAdmissionPolicy.admits(fragment) ? .fragment(fragment) : .rejected
        }

        return .unavailable
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
