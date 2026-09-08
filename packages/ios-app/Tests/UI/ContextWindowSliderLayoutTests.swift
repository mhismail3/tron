import SwiftUI
import XCTest
@testable import TronMobile

/// Small visual checkpoint for the real anchored overlay, not a second drawing
/// of the slider. Device gesture/haptic feel remains a hands-on checkpoint.
@MainActor
final class ContextWindowSliderLayoutTests: XCTestCase {
    func testExpandedGlassAtNarrowWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        for (name, scheme, typeSize) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                         ("dark", .dark, .large), ("large-text", .light, .accessibility3)] {
            let appeared = expectation(description: "Slider host appeared")
            let host = SliderHostingController(rootView: SliderFixture()
                .tronPresentation()
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
                .transaction { $0.disablesAnimations = true })
            host.onAppear = { appeared.fulfill() }
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 540)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKeyAndVisible()
            }
            await fulfillment(of: [appeared], timeout: 2)
            // This is an animation capture, not a readiness or behavior oracle:
            // sample after the control's bounded 420ms opening spring settles.
            try await Task.sleep(for: .milliseconds(600))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, 320)
            let attachment = XCTAttachment(image: image)
            attachment.name = "context-window-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private struct SliderFixture: View {
    private let id = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "brain", title: "Thinking", accent: .tronPurple) {
                        TronInlineActionLabel("Extra High", accent: .tronPurple)
                    }
                    TronSettingsDivider(accent: .tronPurple)
                    TronSettingsRow(icon: "gauge.with.dots.needle.50percent", title: "Context Window", accent: .tronPurple) {
                        TronInlineActionLabel("272,000", accent: .tronPurple)
                            .opacity(0)
                            .anchorPreference(key: ContextWindowSliderPreference.self, value: .bounds) { anchor in
                                ContextWindowSliderRequest(
                                    id: id, anchor: anchor, sourceVerticalInset: 8,
                                    scale: ContextWindowSliderScale(
                                        limits: ContextWindowLimits(minimum: 37_408, maximum: 1_050_000, default: 272_000, longContextThreshold: nil),
                                        defaultValue: 272_000
                                    ), value: 272_000, selection: nil, title: "272,000",
                                    resetLabel: "Use configured default", detail: "Supported model bounds.",
                                    accent: .tronPurple, finish: { _ in }
                                )
                            }
                    }
                    TronSettingsDivider(accent: .tronPurple)
                    TronSettingsRow(icon: "rectangle.compress.vertical", title: "Automatic Compaction", subtitle: "Enabled", accent: .tronPurple)
                }
                .controlSize(.small)
                .tronGlassSurface(accent: .tronPurple)
                .padding(18)
                .padding(.top, 60)
            }
            .navigationTitle("Manage Session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tronContextWindowSliderHost()
    }
}

@MainActor
private final class SliderHostingController<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let completion = onAppear
        onAppear = nil
        completion?()
    }
}
