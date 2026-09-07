import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionSheetPresentationTests: XCTestCase {
    func testManageSessionShowsHeaderlessSessionAndExportCards() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_820).openingTail(targetEncodedBytes: 4_096)
        snapshot.contextUsage = ContextUsage(tokens: 157_000, contextWindow: 272_000, percent: 58)
        try await withModel { model in
            model.installHostedAuthoritativeSnapshot(snapshot)
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(SessionContextSheet(sessionID: snapshot.sessionId, onForkCreated: { _ in })
                    .environment(model).preferredColorScheme(scheme)) { controller in
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                    self.capture(controller, name: "manage-session-top-\(scheme)")
                    scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                    controller.view.layoutIfNeeded()
                    self.capture(controller, name: "manage-session-containers-\(scheme)")
                }
            }
        }
    }

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

    func testDisplayRouteKeepsDocumentChromeWhenMediaIsUnavailable() async throws {
        try await withModel { model in
            let display = DisplayProjection(
                displayId: "display-fixture", title: "Working Plan", altText: "A Markdown plan",
                kind: .markdown, presentation: .init(requestedSurface: .sheet, inlineTapAction: .sheet),
                eligibleSurfaces: [.sheet], fallbackText: "Document is unavailable.",
                artifact: .init(id: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b", name: "plan.md", mimeType: "text/markdown", size: 50, kind: .markdown)
            )
            try await self.withSheet(DisplaySheet(route: DisplayRoute(sessionID: "missing-session", display: display)).environment(model)) { controller in
                XCTAssertEqual(controller.sheetPresentationController?.detents.map(\.identifier), [.large])
                XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                XCTAssertTrue(self.views(of: UIToolbar.self, in: controller.view).allSatisfy(\.isHidden))
            }
        }
    }

    func testDisplayDocumentReaderUsesCustomBlurAndPreservesAuthoredTitle() async throws {
        let text = (0..<40).map { "## Section \($0)\n\nRead the whole document, including the final section.\n" }.joined(separator: "\n")
        try await withModel { model in
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(AttachmentFilePreviewSheet(
                    name: "report.md", mimeType: "text/markdown",
                    source: .local(id: "display-document", data: Data(text.utf8)), title: "Working Plan"
                ).environment(model).preferredColorScheme(scheme)) { controller in
                    XCTAssertEqual(controller.sheetPresentationController?.detents.map(\.identifier), [.large])
                    XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                    scroll.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
                    controller.view.layoutIfNeeded()
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronBlue, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "display-markdown-scrolled-\(scheme)")
                }
            }
        }
    }

    func testCommandPromptContentContainerShowsCompleteScrollableBody() async throws {
        let content = (0..<40).map { "## Instruction \($0)\n\nComplete this step before continuing.\n" }.joined(separator: "\n") + "\nFINAL PROMPT INSTRUCTION"
        let preview = ComposerResourceContentPresentation.preview(content, source: .prompt, sourceTruncated: false)
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Prompt") {
                ScrollView {
                    ComposerResourceContentBody(preview: preview, source: .prompt)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronScrollSurface(accent: .tronPurple, cornerRadius: 16, tintOpacity: 0.06)
                        .padding(18)
                }.tronScrollEdgeChrome()
            }.preferredColorScheme(scheme)) { controller in
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                XCTAssertGreaterThan(scroll.contentSize.height, 2_000, "Prompt containers must include instructions beyond the extension excerpt limit")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                controller.view.layoutIfNeeded()
                self.capture(controller, name: "command-prompt-final-instructions-\(scheme)")
            }
        }
    }

    func testProjectPromptBodyIncludesContentBeyondShortPreviewLimit() async throws {
        let content = (0..<40).map { "## Instruction \($0)\n\nComplete this step before continuing.\n" }.joined(separator: "\n") + "\nFINAL PROMPT INSTRUCTION"
        let detail = CommandResourceDetail(
            name: "review", description: nil, argumentHint: nil, source: .prompt,
            sourcePath: nil, resourceSource: nil, resourceScope: nil, resourceOrigin: nil,
            content: content, contentBytes: content.utf8.count, contentTruncated: false
        )
        try await withSheet(TronDocumentSheet(title: "Prompt") {
            ScrollView {
                ProjectResourcePromptContent(detail: detail).padding(18)
            }.tronScrollEdgeChrome()
        }) { controller in
            let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
            XCTAssertGreaterThan(scroll.contentSize.height, 2_000, "No local excerpt limit should discard prompt instructions")
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            controller.view.layoutIfNeeded()
            self.capture(controller, name: "project-prompt-final-instructions")
        }
    }

    func testPackageSourceFieldUsesSettingsBlueRatherThanGreen() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Install Package") {
                PackageSourceField(source: .constant(""))
                    .padding(20)
                    .frame(maxHeight: .infinity, alignment: .top)
            }.tronSettingsVisualTheme(accent: .tronBlue).preferredColorScheme(scheme)) { controller in
                let field = try XCTUnwrap(self.views(of: UITextField.self, in: controller.view).first)
                let fieldFrame = field.convert(field.bounds, to: controller.view)
                // Sample the painted container beside the text field. Glass
                // and border both used to hard-code emerald despite a blue title.
                let region = CGRect(x: 22, y: fieldFrame.midY - 10, width: 8, height: 20)
                let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                    x: region.minX * image.scale, y: region.minY * image.scale,
                    width: region.width * image.scale, height: region.height * image.scale
                )))
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                XCTAssertGreaterThan(pixel[2], pixel[1], "Source container must be blue, not green (RGBA: \(pixel))")
                self.capture(controller, name: "package-source-\(scheme)")
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
        Color.tronBackground.sheet(isPresented: $presented) { content }
    }
}
