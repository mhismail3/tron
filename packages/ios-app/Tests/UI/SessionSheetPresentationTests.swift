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
