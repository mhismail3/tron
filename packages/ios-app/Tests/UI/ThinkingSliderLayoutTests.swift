import SwiftUI
import XCTest
@testable import TronMobile

/// The source capsule is a fixture; the editor, track and morph host are real.
/// These native captures are not physical-device gesture or haptic validation.
@MainActor
final class ThinkingSliderLayoutTests: XCTestCase {

    func testRetiredSurfaceCannotCommitFromItsClosingAnimation() async throws {
        let presentation = ConfigurationSliderPresentation()
        let registry = PresentationActivityCoordinator()
        let token = PresentationSurfaceToken(id: "thinking-fixture", generation: UUID())
        registry.register(token, parent: nil)
        var completions = 0
        let fixture = ThinkingSliderFixture(presentation: presentation, finish: { _ in completions += 1 })
            .tronPresentation()
            .environment(\.tronPresentationSurfaceToken, token)
            .environment(\.tronPresentationActivityCoordinator, registry)
            // Deliberately hold this projection active. Only a fresh registry
            // read at completion can detect retirement before its next publish.
            .environment(\.tronPresentationActivity, .active)
        try await withHost(fixture) { _ in
            let session = try XCTUnwrap(presentation.session)
            XCTAssertTrue(presentation.beginClosing(session))
            registry.retire(token)
            // Beyond the known 280ms closing duration; no production timer.
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(completions, 0)
            XCTAssertNil(presentation.session, "The retired editor must release its host")
        }
        XCTAssertEqual(registry.mountedSurfaceCount, 0)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func withHost<Content: View>(
        _ content: Content, size: CGSize = CGSize(width: 440, height: 540),
        check: (UIHostingController<Content>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Thinking fixture appeared")
        let host = ThinkingSliderHostingController(rootView: content)
        host.onAppear = { appeared.fulfill() }
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 2)
        try await Task.sleep(for: .milliseconds(400)) // Native opening animation, not model I/O.
        host.view.layoutIfNeeded()
        try await check(host)
    }
}

private struct ThinkingSliderFixture: View {
    let presentation: ConfigurationSliderPresentation
    var levels = ["off", "high", "xhigh"]
    var value = "xhigh"
    var finish: (ThinkingSliderDraft) -> Void = { _ in }
    @State private var owner = UUID()
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "brain", title: "Thinking", accent: .tronPurple) {
                        TronInlineActionLabel(ThinkingLevelPresentation.title(value), accent: .tronPurple)
                            .opacity(presentation.session == nil ? 1 : 0)
                            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                                guard let session = presentation.session else { return nil }
                                return ConfigurationSliderRequest(
                                    session: session, anchor: anchor, sourceVerticalInset: 8, accent: .tronPurple,
                                    editor: .thinking(ThinkingSliderRequest(scale: ThinkingSliderScale(levels: levels), value: value, finish: finish))
                                )
                            }
                    }
                    TronSettingsDivider(accent: .tronPurple)
                    ContextWindowSelectionRow(
                        selection: .constant(nil),
                        limits: ContextWindowLimits(minimum: 37_408, maximum: 1_050_000, default: 272_000, longContextThreshold: nil),
                        inheritedValue: nil, accent: .tronPurple
                    )
                    TronSettingsDivider(accent: .tronPurple)
                    TronSettingsRow(icon: "rectangle.compress.vertical", title: "Automatic Compaction", subtitle: "Enabled", accent: .tronPurple)
                }
                .controlSize(.small).tronGlassSurface(accent: .tronPurple)
                .padding(18).padding(.top, 60)
            }
            .navigationTitle("Manage Session").navigationBarTitleDisplayMode(.inline)
        }
        .tronConfigurationSliderHost(presentation)
        .onAppear { presentation.open(owner: owner, surface: surfaceToken) }
    }
}

@MainActor
private final class ThinkingSliderHostingController<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let completion = onAppear
        onAppear = nil
        completion?()
    }
}
