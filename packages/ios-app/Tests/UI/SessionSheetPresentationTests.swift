import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionSheetPresentationTests: XCTestCase {
    func testInstructionsOpenAsALargeDocumentWithCustomBlurAndNoBottomToolbar() async throws {
        try await withModel { model in
            try await self.withSheet(AgentInstructionsSheet(sessionID: "document-fixture").environment(model)) { controller in
                let sheet = try XCTUnwrap(controller.sheetPresentationController)
                XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.large])
                XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                XCTAssertTrue(self.views(of: UIToolbar.self, in: controller.view).allSatisfy(\.isHidden))
            }
        }
    }

    func testDocumentReaderKeepsFullSelectableInstructions() async throws {
        let instructions = String(repeating: "Read the complete instructions.\n", count: 2_000) + "END OF INSTRUCTIONS"
        try await withModel { model in
            model.installHostedSecondaryProjection(
                context: .object(["systemPrompt": .string(instructions)]), tree: [], commands: [], resources: nil
            )
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(AgentInstructionsSheet(sessionID: "document-fixture")
                    .environment(model).preferredColorScheme(scheme)) { controller in
                    let reader = try XCTUnwrap(self.views(of: UITextView.self, in: controller.view).first)
                    XCTAssertEqual(reader.text, instructions)
                    XCTAssertTrue(reader.isSelectable)
                    XCTAssertTrue(reader.isScrollEnabled)
                    XCTAssertFalse(reader.isEditable)
                    let readerFrame = reader.convert(reader.bounds, to: controller.view)
                    // Both edges belong to the viewport, not empty safe-area
                    // strips. Internal scroll insets protect the first/last lines.
                    XCTAssertEqual(readerFrame.maxY, controller.view.bounds.maxY, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(
                        reader.textContainerInset.bottom + reader.adjustedContentInset.bottom,
                        controller.view.safeAreaInsets.bottom
                    )
                    XCTAssertEqual(readerFrame.minY, controller.view.bounds.minY, accuracy: 1,
                                   "The reader must scroll behind the blur, not clip below the title")
                    let firstLine = reader.convert(reader.caretRect(for: reader.beginningOfDocument), to: controller.view)
                    XCTAssertGreaterThanOrEqual(firstLine.minY, controller.view.safeAreaInsets.top,
                                                "Opening the full-height reader must not hide its first line")
                    let blurs = self.views(of: VariableBackdropBlurView.self, in: controller.view)
                    XCTAssertEqual(blurs.count, 1)
                    let blur = try XCTUnwrap(blurs.first)
                    let blurFrame = blur.convert(blur.bounds, to: controller.view)
                    XCTAssertGreaterThan(blurFrame.maxY, controller.view.safeAreaInsets.top + 20,
                                         "The fade must continue below navigation, not end at a hard boundary")
                    let geometry = XCTAttachment(string: "reader: \(readerFrame), blur: \(blurFrame), adjusted: \(reader.adjustedContentInset)")
                    geometry.name = "instructions-geometry-\(scheme)"
                    geometry.lifetime = .keepAlways
                    self.add(geometry)
                    reader.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
                    controller.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "instructions-scrolled-document-\(scheme)"
                    attachment.lifetime = .keepAlways
                    self.add(attachment)
                }
            }
        }
    }

    func testSubagentListsStartAtMediumOnEachPresentation() async throws {
        try await withModel { model in
            for _ in 0..<2 {
                try await self.withSheet(ProcessHistorySheet(sessionID: "history-fixture").environment(model)) { controller in
                    let sheet = try XCTUnwrap(controller.sheetPresentationController)
                    XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
                    XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
                    // Users can still expand this presentation; a fresh presentation starts medium.
                    sheet.selectedDetentIdentifier = .large
                }
                try await self.withSheet(SessionProcessesSheet(sessionID: "process-fixture").environment(model)) { controller in
                    XCTAssertEqual(controller.sheetPresentationController?.selectedDetentIdentifier, .medium)
                }
            }
        }
    }

    func testComposerResourceDetailsKeepMetadataSecondaryAndMatchToolbarPaint() async throws {
        try await withModel { model in
            for (source, accent): (CommandInfo.Source, Color) in [(.skill, .tronCyan), (.prompt, .tronPurple), (.extension, .tronIndigo)] {
                let entry = try XCTUnwrap(ComposerResourceEntry(command: CommandInfo(
                    name: source == .skill ? "skill:review" : "review",
                    description: "Review the selected changes.", argumentHint: "Optional focus",
                    source: source, sourcePath: "/resources/review.md",
                    resourceSource: "project resources", resourceScope: .project, resourceOrigin: .topLevel
                )))
                try await self.withSheet(ComposerResourceDetailSheet(
                    sessionID: nil, entry: entry, accent: accent, prefix: source == .skill ? "@" : "/"
                ).environment(model)) { controller in
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(accent, bar: bar, leading: true, controller: controller)
                    self.assertToolbarPaint(accent, bar: bar, leading: false, controller: controller)
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    // With a short description and no fetched body, a main-sheet
                    // resource table would exceed this independently measured bound.
                    XCTAssertLessThan(scroll.contentSize.height, 250)
                    self.capture(controller, name: "resource-detail-\(source)")
                }
                let metadata = [
                    TronTechnicalMetadataItem(title: "Type", value: source.rawValue, icon: "sparkles"),
                    .init(title: "Invocation", value: source == .skill ? "@review" : "/review", icon: "terminal"),
                    .init(title: "Source file", value: "/resources/review.md", icon: "doc.text"),
                ]
                try await self.withSheet(ComposerResourceInfoSheet(items: metadata, accent: accent)) { controller in
                    XCTAssertEqual(controller.sheetPresentationController?.selectedDetentIdentifier, .medium)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(accent, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "resource-info-\(source)")
                }
            }
        }
    }

    private func capture(_ controller: UIViewController, name: String) {
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// SwiftUI paints these symbols without public UIButton/customView nodes.
    /// In this short-title fixture each outer quarter contains only its action;
    /// sample actual paint there rather than the bar's inherited UIKit tint.
    private func assertToolbarPaint(_ accent: Color, bar: UINavigationBar, leading: Bool, controller: UIViewController) {
        let regionWidth = bar.bounds.width / 4
        let region = CGRect(x: leading ? 0 : bar.bounds.width - regionWidth, y: 0, width: regionWidth, height: bar.bounds.height)
        let frame = bar.convert(region, to: controller.view)
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        guard let crop = image.cgImage?.cropping(to: CGRect(
            x: frame.minX * image.scale, y: frame.minY * image.scale,
            width: frame.width * image.scale, height: frame.height * image.scale
        )) else { return XCTFail("Toolbar control must have a rendered frame") }
        let width: Int = crop.width, height: Int = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).resolvedColor(with: controller.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        var matches = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = abs(CGFloat(pixels[index]) / 255 - r)
            let green = abs(CGFloat(pixels[index + 1]) / 255 - g)
            let blue = abs(CGFloat(pixels[index + 2]) / 255 - b)
            if red < 0.05, green < 0.05, blue < 0.05, pixels[index + 3] > 230 { matches += 1 }
        }
        XCTAssertGreaterThan(matches, 3, "Toolbar symbol must match its resource title color")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let suiteName = "session-sheet-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let model = AppModel(profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: cacheURL))
        try await body(model)
    }

    private func withSheet<Sheet: View>(_ sheet: Sheet, inspect: (UIViewController) throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Sheet appeared")
        let host = UIHostingController(rootView: SheetFixture(content: sheet.onAppear { appeared.fulfill() }))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let appearance = await XCTWaiter.fulfillment(of: [appeared], timeout: 3)
        XCTAssertEqual(appearance, .completed)
        let presented = try XCTUnwrap(host.presentedViewController)
        if let transition = presented.transitionCoordinator {
            let completed = expectation(description: "Sheet transition completed")
            if transition.animate(alongsideTransition: nil, completion: { _ in completed.fulfill() }) {
                let result = await XCTWaiter.fulfillment(of: [completed], timeout: 3)
                XCTAssertEqual(result, .completed)
            }
        }
        presented.view.layoutIfNeeded()
        // Always finish UIKit dismissal, even if the inspection throws.
        var failure: Error?
        do { try inspect(presented) } catch { failure = error }
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        if let failure { throw failure }
    }

    private func views<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }
}

private struct SheetFixture<Content: View>: View {
    let content: Content
    @State private var presented = true

    var body: some View {
        Color.clear.sheet(isPresented: $presented) { content }
    }
}
