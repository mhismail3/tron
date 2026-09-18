import SwiftUI
import XCTest
@testable import TronMobile

/// The expanded thinking trace starts at a consistent position, and the shared
/// top blur band covers the sheet's chrome without washing the first resting
/// line. These are hosted-sheet checks, not physical-device visual acceptance.
@MainActor
final class ThinkingTraceSheetTests: XCTestCase {
    private static let longTrace = (1...60)
        .map { "Reasoning line \($0) with enough words to wrap across two lines of the sheet width." }
        .joined(separator: "\n")
    private static let shortTrace = (1...4).map { "Reasoning line \($0)" }.joined(separator: "\n")

    func testThinkingTraceStartsAtRestAndClearsTheTopBlurBand() async throws {
        for (name, streaming, source) in [
            ("completed-short", false, Self.shortTrace),
            ("completed-long", false, Self.longTrace),
            ("streaming-long", true, Self.longTrace),
        ] {
            let sheet = ThinkingTraceDetailSheet(
                inline: MarkdownPresentation.Inline(source: source),
                identity: "thinking-trace-test",
                streaming: streaming
            )
            try await withSheet(sheet) { controller in
                controller.view.layoutIfNeeded()
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                let restingOffset = -scroll.adjustedContentInset.top
                if streaming {
                    XCTAssertGreaterThan(scroll.contentOffset.y, restingOffset + 1,
                                         "\(name): a streaming trace follows its tail")
                } else {
                    XCTAssertEqual(scroll.contentOffset.y, restingOffset, accuracy: 0.5,
                                   "\(name): a completed trace rests at its beginning instead of one row down")
                }

                // The band holds its effect through the sheet's chrome and ends
                // at or above the first resting line (the scroll inset plus the
                // content's own padding).
                XCTAssertGreaterThanOrEqual(TronTopBlurStyle.sheet.solidHeight, bar.frame.maxY,
                                            "\(name): the solid band must cover the navigation chrome")
                XCTAssertLessThanOrEqual(TronTopBlurStyle.sheet.height, scroll.adjustedContentInset.top + 18,
                                         "\(name): the band must clear the first resting line")
                self.capture(controller, name: "thinking-trace-\(name)")
            }
        }
    }

    func testTopBlurProfileHoldsTheChromeAndPreservesExistingBands() {
        // A 30% solid fraction (chat, dashboard, logs) reproduces the previous
        // proportional profile exactly.
        XCTAssertEqual(TronTopBlurProfile.locations(solidFraction: 0.30, base: [0, 0.14, 0.30, 0.46, 1]),
                       [0, 0.14, 0.30, 0.46, 1])
        // Sheet styles hold their full effect through the chrome, then fade.
        let solid = TronTopBlurProfile.solidFraction(of: .sheet)
        let locations = TronTopBlurProfile.locations(solidFraction: solid, base: [0, 0.14, 0.30, 0.46, 0.61, 1])
        XCTAssertEqual(locations.first, 0)
        XCTAssertEqual(locations.last, 1)
        XCTAssertTrue(zip(locations, locations.dropFirst()).allSatisfy { $0 < $1 }, "Stops stay ordered")
        XCTAssertTrue(locations.filter { $0 <= solid + 0.0001 }.count >= 3,
                      "The base's hold stops stay inside the solid band")
        for style in [TronTopBlurStyle.chat, .dashboard, .sheet, .toolDetail, .logs] {
            XCTAssertGreaterThan(style.solidHeight, 0)
            XCTAssertLessThanOrEqual(style.solidHeight, style.height, "The solid band cannot exceed its band")
        }
        XCTAssertLessThan(TronTopBlurStyle.toolDetail.height, TronTopBlurStyle.sheet.height + 1,
                          "Sheet and tool-detail surfaces share one band")
    }

    private func capture(_ controller: UIViewController, name: String) {
        guard let window = controller.view.window else { return XCTFail("Capture requires a mounted sheet") }
        let origin = controller.view.convert(controller.view.bounds, to: window).origin
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in
            context.cgContext.translateBy(x: -origin.x, y: -origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func views<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }

    private func withSheet<Sheet: View>(_ sheet: Sheet, inspect: (UIViewController) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Sheet appeared")
        let host = UIHostingController(rootView: ThinkingTraceSheetFixture(content: sheet.onAppear { appeared.fulfill() }))
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
                _ = await XCTWaiter.fulfillment(of: [completed], timeout: 3)
            }
        }
        presented.view.layoutIfNeeded()
        var failure: Error?
        do { try await inspect(presented) } catch { failure = error }
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        if let failure { throw failure }
    }
}

@MainActor
private struct ThinkingTraceSheetFixture<Content: View>: View {
    let content: Content
    @State private var presented = true

    var body: some View {
        Color.tronBackground.sheet(isPresented: $presented) { content }
    }
}
