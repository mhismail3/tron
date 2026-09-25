import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class DashboardChromeTests: XCTestCase {

    func testHeaderMotionIsSmallBoundedReversibleAndRespectsReduceMotion() {
        let state = DashboardHeaderState()
        let samples: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 25, 1), (40, 12.5, 33 / 34), (80, 0, 32 / 34), (800, 0, 32 / 34),
            (40, 12.5, 33 / 34), (0, 25, 1), (-60, 25, 1.03), (-120, 25, 1.06),
            (-800, 25, 1.06), (0, 25, 1),
        ]
        for (offset, y, scale) in samples {
            state.update(offset: offset)
            XCTAssertEqual(state.verticalOffset(reduceMotion: false), y, accuracy: 0.0001)
            XCTAssertEqual(state.titleScale(reduceMotion: false), scale, accuracy: 0.0001)
            XCTAssertEqual(state.verticalOffset(reduceMotion: true), 0)
            XCTAssertEqual(state.titleScale(reduceMotion: true), 1)
        }
        state.update(offset: -60)
        state.update(offset: DashboardHeaderState.boundedOffset(.nan))
        state.update(offset: DashboardHeaderState.boundedOffset(-.infinity))
        state.update(offset: DashboardHeaderState.boundedOffset(.infinity))
        XCTAssertEqual(state.offset, -60, "Invalid geometry cannot reset a live gesture")
        XCTAssertEqual(state.progress, 0, "Pull-down never reveals the blur")
    }

    func testSearchRetainsQueryAfterKeyboardDismissalAndCapturesResults() async throws {
        try await assertSearchChrome(style: .light)
    }

    private func assertSearchChrome(style: UIUserInterfaceStyle) async throws {
        try await withDashboard(style: style) { host in
            let menu = try await self.menuButton(in: host.view)
            self.invoke(try self.action("Search", in: menu))
            try await self.waitUntil { self.views(UITextField.self, in: host.view).contains { $0.isFirstResponder } }
            let field = try XCTUnwrap(self.views(UITextField.self, in: host.view).first { $0.isFirstResponder })
            field.text = "Review"
            field.sendActions(for: .editingChanged)
            try await Task.sleep(for: .milliseconds(350))
            host.view.endEditing(true)
            try await self.waitUntil { !field.isFirstResponder }
            XCTAssertEqual(field.text, "Review", "Dismissing the keyboard must not dismiss an active search")
            try await self.attach(host.view, name: "session-search-results-\(style == .dark ? "dark" : "light")")
        }
    }

    func testPresentedMenuKeepsItsGraphAndRefreshesOnNextOpening() async throws {
        var invocations: [Int] = []
        @MainActor func parent(_ revision: Int) -> DashboardModeMenuButton {
            DashboardModeMenuButton(mode: .knowledge, onSelect: { _ in }, actions: .init(
                search: {}, filter: {}, settings: {},
                settingsMenu: .init(title: "Knowledge settings", symbol: "slider.horizontal.3", actions: [
                    .init(title: "Observation configuration", symbol: "eye", perform: { invocations.append(revision) }),
                ]),
                creation: [.init(title: "New note \(revision)", symbol: "note.text.badge.plus", perform: {})]
            ))
        }
        let coordinator = parent(0).makeCoordinator()
        let button = coordinator.makeButton()
        button.sendActions(for: .menuActionTriggered)
        let presentedMenu = try XCTUnwrap(button.menu)
        for revision in 1...3 {
            coordinator.update(button, parent: parent(revision))
            XCTAssertTrue(button.menu === presentedMenu, "SwiftUI refreshes must leave UIKit's menu graph intact")
        }
        invoke(try action("Observation configuration", in: button))
        try await waitUntil { invocations == [0] }

        coordinator.update(button, parent: parent(4))
        button.sendActions(for: .menuActionTriggered)
        XCTAssertFalse(button.menu === presentedMenu, "Every opening gets the current controls and callbacks")
        XCTAssertEqual(try action("New note 4", in: button).title, "New note 4")
        invoke(try action("Observation configuration", in: button))
        try await waitUntil { invocations == [0, 4] }
    }

    private func action(_ title: String, in button: UIButton) throws -> UIAction {
        func actions(in menu: UIMenu) -> [UIAction] {
            menu.children.flatMap { element -> [UIAction] in
                if let nested = element as? UIMenu { return actions(in: nested) }
                return (element as? UIAction).map { [$0] } ?? []
            }
        }
        return try XCTUnwrap(actions(in: XCTUnwrap(button.menu)).first { $0.title == title })
    }

    private func invoke(_ action: UIAction) {
        let sender = UIButton()
        sender.addAction(action, for: .touchUpInside)
        sender.sendActions(for: .touchUpInside)
    }

    private func menuButton(in view: UIView) async throws -> UIButton {
        try await waitUntil { self.views(UIButton.self, in: view).contains { $0.accessibilityIdentifier == "dashboard.menu" } }
        return try XCTUnwrap(views(UIButton.self, in: view).first { $0.accessibilityIdentifier == "dashboard.menu" })
    }

    private func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Hosted dashboard did not reach the expected state", file: file, line: line)
    }

    private func attach(_ view: UIView, name: String) async throws {
        // Layout/semantic readiness is checked by the caller. Let the existing
        // 280ms content reveal finish before recording the visual artifact.
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func withDashboard(
        style: UIUserInterfaceStyle = .dark,
        dynamicType: DynamicTypeSize = .large,
        _ check: (UIViewController) async throws -> Void
    ) async throws {
        // Search changes the persisted Automation view. Bound that write to
        // this hosted-test fixture and restore the exact prior preference.
        let preferenceKey = AutomationDashboardPreferences.documentKey
        let previousPreference = UserDefaults.standard.object(forKey: preferenceKey)
        AutomationDashboardPreferences.save(AutomationDashboardViewPreferences())
        defer { UserDefaults.standard.set(previousPreference, forKey: preferenceKey) }
        let suite = "dashboard-header-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cache = FileManager.default.temporaryDirectory.appending(path: suite)
        let model = AppModel(profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: cache))
        model.sessions = (0..<30).map { index in
            SessionSummary(id: "session-\(index)", name: ["Review the project", "Plan the next release", "Explore design ideas"][index % 3],
                           cwd: "/workspace/project-\(index / 5)", parentSessionId: nil,
                           createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                           messageCount: 1, firstMessage: "Example conversation", phase: .idle, summaryRevision: 1)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: SessionShellView()
            .environment(model)
            .environment(\.tronPresentationActivityCoordinator, PresentationActivityCoordinator())
            // A hosted fixture has no SwiftUI Scene; provide the scene input,
            // while leaving surface/sheet lifecycles with their real owners.
            .environment(\.scenePhase, .active)
            .environment(\.dynamicTypeSize, dynamicType)
            .tronPresentation())
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        var failure: Error?
        do {
            try await waitUntil { !self.views(UIButton.self, in: host.view).isEmpty }
            host.view.layoutIfNeeded()
            try await check(host)
        } catch { failure = error }
        window.isHidden = true
        window.rootViewController = nil
        await model.teardown()
        if let failure { throw failure }
    }
}
