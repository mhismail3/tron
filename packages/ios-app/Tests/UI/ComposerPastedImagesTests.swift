import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import TronMobile

@MainActor
@Suite("Composer image paste")
struct ComposerPastedImagesTests {

    @Test("empty and oversized image data fail before upload")
    func byteBounds() async throws {
        for data in [Data(), Data(repeating: 1, count: 32)] {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            await #expect(throws: ComposerPastedImages.ImportError.self) {
                _ = try await ComposerPastedImages.load(provider, maximumBytes: 16)
            }
        }
    }

    // Failure modes (#407): an iPhone photo copies as public.heic first. Uploading
    // it raw put an image type no provider accepts into the session, so every
    // later turn was rejected. A copy must upload a provider-accepted format,
    // must not be transcoded when one is already offered, and must fail visibly
    // rather than upload bytes that cannot be decoded.
    @Test("a copy that offers a provider-accepted format uploads it unchanged")
    func prefersAcceptedRepresentation() async throws {
        let png = try #require(image(.red).pngData())
        let provider = NSItemProvider()
        register(Data("not decoded".utf8), as: .heic, on: provider)
        register(png, as: .png, on: provider)
        let candidate = try await ComposerPastedImages.load(provider, maximumBytes: 1_048_576)
        #expect(candidate.mimeType == "image/png")
        #expect(candidate.name == "photo.png")
        #expect(candidate.data == png)
    }

    @Test("a copy offering only a format providers reject uploads as JPEG")
    func transcodesRejectedFormat() async throws {
        let original = image(.blue)
        let tiff = try encoded(original, as: .tiff)
        let provider = NSItemProvider()
        register(tiff, as: .tiff, on: provider)
        let candidate = try await ComposerPastedImages.load(provider, maximumBytes: 1_048_576)
        #expect(candidate.mimeType == "image/jpeg")
        #expect(candidate.name == "photo.jpg")
        let source = try #require(CGImageSourceCreateWithData(candidate.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == original.cgImage?.width)
    }

    @Test("undecodable bytes in a rejected format fail instead of uploading")
    func undecodableRejectedFormat() async {
        let provider = NSItemProvider()
        register(Data("not an image".utf8), as: .heic, on: provider)
        await #expect(throws: ComposerPastedImages.ImportError.self) {
            _ = try await ComposerPastedImages.load(provider, maximumBytes: 1_024)
        }
    }

    @Test("one paste delivers ordered images once without changing draft text or selection")
    func imagePasteKeepsText() {
        let view = MultilineComposerTextView.LayoutAwareTextView()
        view.text = "Keep this draft"
        view.selectedRange = NSRange(location: 5, length: 4)
        let first = NSItemProvider(object: image(.red))
        let second = NSItemProvider(object: image(.blue))
        let text = NSItemProvider(object: "https://example.test/image" as NSString)
        var batches: [[NSItemProvider]] = []
        view.onPasteImages = { batches.append($0) }
        #expect(view.canPaste([first, second]))
        view.paste(itemProviders: [first, text, second])
        #expect(batches.count == 1)
        #expect(batches[0].count == 2)
        #expect(batches[0][0] === first && batches[0][1] === second)
        #expect(view.text == "Keep this draft")
        #expect(view.selectedRange == NSRange(location: 5, length: 4))
        view.isEditable = false
        view.paste(itemProviders: [first])
        #expect(batches.count == 1)
    }

    @Test("overflow is reported to the owner instead of silently dropping copied images")
    func overflowSelection() {
        let view = MultilineComposerTextView.LayoutAwareTextView()
        var count = 0
        view.onPasteImages = { count = $0.count }
        let provider = NSItemProvider(object: image(.red))
        view.paste(itemProviders: Array(repeating: provider, count: 100))
        #expect(count == ChatAttachmentImportPolicy.maximumPhotoSelection + 1)
    }

    @Test("an outgoing editor cannot paste into a replacement draft before UIKit updates")
    func staleScope() {
        var authority = ComposerTextAuthority(scope: .init(profileID: "p", sessionID: "old"), revision: 1)
        var pasted = 0
        let control = MultilineComposerTextView(text: .constant("draft"), isFocused: .constant(true),
            authoritativeTextRevision: Binding(get: { authority }, set: { _ in }),
            isEditable: true, keyboardAppearance: .dark, onPasteImages: { _ in pasted += 1 })
        let coordinator = control.makeCoordinator()
        let view = UITextView()
        coordinator.reconcileAuthoritativeText(on: view)
        let providers = [NSItemProvider(object: image(.red))]
        coordinator.pasteImages(providers)
        #expect(pasted == 1)
        authority = ComposerTextAuthority(scope: .init(profileID: "p", sessionID: "new"), revision: 1)
        coordinator.pasteImages(providers)
        #expect(pasted == 1)
    }

    @Test("cancellation releases a pending provider and ignores its late completion")
    func cancelledProvider() async throws {
        let gate = PasteProviderGate()
        let task = Task { try await ComposerPastedImages.load(gate.provider(), maximumBytes: 1_024) }
        let deadline = Date().addingTimeInterval(3)
        while !gate.started, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.started)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        gate.finish()
    }

    private func register(_ data: Data, as type: UTType, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }

    private func encoded(_ image: UIImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

private final class PasteProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((URL?, Bool, Error?) -> Void)?
    var started: Bool { lock.withLock { completion != nil } }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            self.lock.withLock { self.completion = completion }
            return Progress(totalUnitCount: 1)
        }
        return provider
    }

    func finish() {
        let callback = lock.withLock {
            let value = completion
            completion = nil
            return value
        }
        callback?(nil, false, CocoaError(.userCancelled))
    }
}
