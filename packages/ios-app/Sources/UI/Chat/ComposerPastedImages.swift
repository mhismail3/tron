import Foundation
import UniformTypeIdentifiers

/// Clipboard representations become the same upload candidates as PhotosPicker.
/// Read temporary provider files inside their callback lifetime, before admitting
/// any bytes to the draft; no full-resolution UIImage decoding is needed here.
enum ComposerPastedImages {
    static func containsImages(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    @MainActor
    static func load(_ provider: NSItemProvider, maximumBytes: Int) async throws -> ComposerAttachmentUploadCandidate {
        guard maximumBytes > 0 else { throw ImportError.tooLarge }
        guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            .first(where: { $0.conforms(to: .image) && $0.preferredMIMEType != nil }),
              let mimeType = type.preferredMIMEType else { throw ImportError.unsupported }
        let load = ProviderLoad()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard load.install(continuation) else { return }
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    let result = Result<Data, Error> {
                        if let error { throw error }
                        guard let url, url.isFileURL else { throw ImportError.unsupported }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0 else { throw ImportError.empty }
                        guard size <= maximumBytes else { throw ImportError.tooLarge }
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard !data.isEmpty, data.count <= maximumBytes else { throw ImportError.tooLarge }
                        return data
                    }
                    load.finish(result)
                }
                load.install(progress)
            }
        } onCancel: {
            load.cancel()
        }
        try Task.checkCancellation()
        return .init(name: "photo.\(type.preferredFilenameExtension ?? "image")", mimeType: mimeType, data: data)
    }

    enum ImportError: LocalizedError {
        case unsupported, empty, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupported: "The copied image could not be prepared."
            case .empty: "The copied image is empty."
            case .tooLarge: "Attach at most 10 files totaling 25 MiB."
            }
        }
    }

    /// NSItemProvider can complete synchronously, or after cancellation. Retire
    /// the continuation exactly once and cancel even a late-installed Progress.
    private final class ProviderLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var progress: Progress?
        private var finished = false
        private var cancelled = false

        func install(_ value: CheckedContinuation<Data, Error>) -> Bool {
            let accepted = lock.withLock {
                guard !finished else { return false }
                continuation = value
                return true
            }
            if !accepted { value.resume(throwing: CancellationError()) }
            return accepted
        }

        func install(_ value: Progress) {
            let shouldCancel = lock.withLock {
                if !finished { progress = value }
                return cancelled
            }
            if shouldCancel { value.cancel() }
        }

        func finish(_ result: Result<Data, Error>) {
            let pending = lock.withLock {
                guard !finished else { return Optional<CheckedContinuation<Data, Error>>.none }
                finished = true
                let pending = continuation
                continuation = nil
                progress = nil
                return pending
            }
            pending?.resume(with: result)
        }

        func cancel() {
            let pending = lock.withLock {
                cancelled = true
                finished = true
                let pending = (continuation, progress)
                continuation = nil
                progress = nil
                return pending
            }
            pending.0?.resume(throwing: CancellationError())
            pending.1?.cancel()
        }
    }
}
