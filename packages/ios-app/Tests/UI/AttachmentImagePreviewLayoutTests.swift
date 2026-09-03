import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Attachment image preview layout", .serialized)
struct AttachmentImagePreviewLayoutTests {
    @Test("local full preview replaces the initial thumbnail")
    func localFullPreviewReplacement() async throws {
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 24, height: 24)))
        }
        let fullPreview = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 240, height: 240)))
        }
        let suite = "AttachmentImagePreviewLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suite)
        let model = AppModel(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot)
        )
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let controller = UIHostingController(
            rootView: AttachmentImagePreviewSheet(image: thumbnail).environment(model)
        )
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let imageView = try await Self.waitForPreviewImageView(in: controller.view)
        #expect(imageView.image === thumbnail)

        controller.rootView = AttachmentImagePreviewSheet(image: fullPreview).environment(model)
        for _ in 0..<20 where imageView.image !== fullPreview {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
        }
        #expect(imageView.image === fullPreview)
    }

    private static func waitForPreviewImageView(in view: UIView) async throws -> UIImageView {
        for _ in 0..<20 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if let imageView = previewImageView(in: view) { return imageView }
            await Task.yield()
        }
        throw AttachmentImagePreviewTestError.imageViewUnavailable
    }

    private static func previewImageView(in view: UIView) -> UIImageView? {
        if let imageView = view as? UIImageView,
           imageView.accessibilityHint == "Pinch or double tap to zoom" {
            return imageView
        }
        for child in view.subviews {
            if let match = previewImageView(in: child) { return match }
        }
        return nil
    }
}

private enum AttachmentImagePreviewTestError: Error {
    case imageViewUnavailable
}
