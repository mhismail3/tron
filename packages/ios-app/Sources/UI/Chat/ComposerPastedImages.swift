import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image formats every model provider accepts inline. A photo in any other
/// format (an iPhone copies HEIC) is re-encoded as JPEG here on the device,
/// because the Gateway's model runtime cannot decode HEIC and a rejected inline
/// image breaks every later turn of its session (#407).
enum ProviderImageFormat {
    static let accepted: [UTType] = [.jpeg, .png, .gif, .webP]

    static func isAccepted(_ type: UTType) -> Bool {
        accepted.contains { type.conforms(to: $0) }
    }

    /// Full-resolution JPEG with the source orientation applied to the pixels
    /// (EXIF orientation and other metadata are not carried over), or nil when
    /// the bytes cannot be decoded.
    static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

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
        let images = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            .filter { $0.conforms(to: .image) && $0.preferredMIMEType != nil }
        // Prefer a representation the provider can already use over transcoding.
        guard let type = images.first(where: ProviderImageFormat.isAccepted) ?? images.first,
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
        if ProviderImageFormat.isAccepted(type) {
            return .init(name: "photo.\(type.preferredFilenameExtension ?? "image")", mimeType: mimeType, data: data)
        }
        guard let jpeg = ProviderImageFormat.jpeg(from: data) else { throw ImportError.unsupported }
        guard jpeg.count <= maximumBytes else { throw ImportError.tooLarge }
        return .init(name: "photo.jpg", mimeType: "image/jpeg", data: jpeg)
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
