import SwiftUI
import XCTest
@testable import TronMobile

/// The source capsule is a fixture; the editor, track and morph host are real.
/// These native captures are not physical-device gesture or haptic validation.
@MainActor
final class ThinkingSliderLayoutTests: XCTestCase {
    func testSupportedLevelLayouts() async throws {
        let all = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        for (name, width, height, scheme, size, levels, value) in [
            ("phone", CGFloat(440), CGFloat(540), ColorScheme.light, DynamicTypeSize.large, all, "xhigh"),
            ("narrow", 320, 540, .light, .large, all, "xhigh"),
            ("dark", 320, 540, .dark, .large, all, "high"),
            ("large-text", 320, 620, .light, .accessibility3, all, "xhigh"),
            ("short-large-text", 440, 140, .light, .accessibility3, all, "max"),
            ("runtime-subset", 320, 540, .light, .large, ["off", "high", "xhigh"], "high"),
            ("unlisted-current", 320, 540, .light, .large, ["off", "high", "xhigh"], "adaptive"),
        ] {
            let presentation = ConfigurationSliderPresentation()
            let fixture = ThinkingSliderFixture(presentation: presentation, levels: levels, value: value)
                .tronPresentation().environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
            try await withHost(fixture, size: CGSize(width: width, height: height)) { host in
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                XCTAssertEqual(image.size.width, width)
                XCTAssertNotNil(presentation.session, "The actual editor must be mounted")
                if size == .large {
                    let editor = try XCTUnwrap(scrollViews(in: host.view).first {
                        abs($0.bounds.width - (width - 36)) < 1 && $0.bounds.height > 0
                    })
                    XCTAssertEqual(editor.bounds.height, 140, accuracy: 1, "Thinking needs only the header and rail")
                    XCTAssertLessThanOrEqual(editor.contentSize.height, editor.bounds.height + 1,
                        "The normal-size editor must fit without a lower label section")
                }
                if name == "short-large-text" {
                    let overflowing = scrollViews(in: host.view).filter {
                        !$0.isHidden && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 1
                    }
                    XCTAssertGreaterThanOrEqual(overflowing.count, 2,
                        "Both the short sheet and its overflowing editor must remain scrollable")
                    let editor = try XCTUnwrap(overflowing.min { $0.bounds.width < $1.bounds.width })
                    let bottom = editor.contentSize.height - editor.bounds.height
                    editor.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    host.view.layoutIfNeeded()
                    XCTAssertEqual(editor.contentOffset.y, bottom, accuracy: 1)
                    XCTAssertGreaterThan(bottom, 0)
                    let scrolled = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: scrolled)
                    attachment.name = "thinking-slider-short-large-text-scrolled"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "thinking-slider-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testDismissalCompletesOnceWithoutChangingAnUneditedValue() async throws {
        let presentation = ConfigurationSliderPresentation()
        let finished = expectation(description: "Editor finished")
        let recorder = RecordingPerformanceSignposts()
        var drafts: [ThinkingSliderDraft] = []
        try await withHost(ThinkingSliderFixture(presentation: presentation, finish: { draft in
            drafts.append(draft)
            finished.fulfill()
        }).tronPresentation().environment(\.configurationSliderSignposts, recorder)) { _ in
            let session = try XCTUnwrap(presentation.session)
            XCTAssertTrue(presentation.beginClosing(session))
            XCTAssertFalse(presentation.beginClosing(session))
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(drafts.count, 1)
            XCTAssertNil(drafts[0].selectionToCommit(currentValue: "xhigh", levels: ["off", "high", "xhigh"]))
            XCTAssertNil(presentation.session)
            XCTAssertEqual(recorder.events(), [
                .begin(.configurationSliderExpand), .end(.configurationSliderExpand, .success, .none),
                .begin(.configurationSliderCollapse), .end(.configurationSliderCollapse, .success, .none)
            ])
        }
    }

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
