import SwiftUI
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import TronMobile

@MainActor
@Suite("Composer image paste")
struct ComposerPastedImagesTests {
    @Test("UIKit image providers load as photo upload candidates without losing their representation")
    func imageProvider() async throws {
        let provider = NSItemProvider(object: image(.red))
        #expect(ComposerPastedImages.containsImages([provider]))
        let candidate = try await ComposerPastedImages.load(provider, maximumBytes: 25 * 1_048_576)
        #expect(candidate.mimeType.hasPrefix("image/"))
        #expect(candidate.name.hasPrefix("photo."))
        #expect(UIImage(data: candidate.data) != nil)
    }

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
