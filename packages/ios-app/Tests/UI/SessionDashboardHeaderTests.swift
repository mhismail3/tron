import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class SessionDashboardHeaderTests: XCTestCase {
    func testNativeLogoSizingKeepsToolbarIconsUnchanged() {
        let button = DashboardLogoButton(type: .custom)
        button.setImage(UIImage(named: "TronLogoVector"), for: .normal)
        button.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        button.layoutIfNeeded()
        XCTAssertEqual(button.imageView?.bounds.size, CGSize(width: 24, height: 24))
        button.logoSize = 34
        button.frame.size = CGSize(width: 56, height: 56)
        button.layoutIfNeeded()
        XCTAssertEqual(button.imageView?.bounds.size, CGSize(width: 34, height: 34))
        XCTAssertEqual(button.imageView?.center, CGPoint(x: 28, y: 28))
    }

    func testScrollProgressIsBoundedReversibleAndIgnoresInvalidGeometry() {
        let state = SessionDashboardHeaderState()
        for (offset, expected): (CGFloat, CGFloat) in [(-80, 0), (0, 0), (20, 0.25), (40, 0.5), (80, 1), (800, 1), (40, 0.5), (0, 0)] {
            state.update(offset: offset)
            XCTAssertEqual(state.progress, expected)
        }
        state.update(offset: .nan)
        XCTAssertEqual(state.progress, 0)
        state.update(offset: .infinity)
        XCTAssertEqual(state.progress, 0)
    }

    func testMenuSectionsAndActionsRetainTheirOwners() async throws {
        var selected: DashboardMode?
        var invoked: [String] = []
        let button = DashboardModeMenuButton(mode: .sessions, onSelect: { selected = $0 }, sessionActions: .init(
            search: { invoked.append("Search") }, filter: { invoked.append("Filter") },
            settings: { invoked.append("Settings") }, newSession: { invoked.append("New Session") }
        ))
        let coordinator = button.makeCoordinator()
        let menu = coordinator.makeMenu()
        let sections = menu.children.compactMap { $0 as? UIMenu }
        XCTAssertEqual(sections.count, 4)
        XCTAssertTrue(sections.allSatisfy { $0.options.contains(.displayInline) })
        XCTAssertEqual(sections.map { $0.children.map(\.title) }, [
            ["Sessions", "Automations", "Knowledge"], ["Search", "Filter"], ["Settings"], ["New Session"],
        ])
        XCTAssertNil((sections[1].children[1] as? UIAction)?.subtitle, "Filter stays a single-line entry")
        let dashboards = sections[0].children.compactMap { $0 as? UIAction }
        XCTAssertEqual(dashboards.map(\.state), [.on, .off, .off])
        XCTAssertTrue(dashboards.allSatisfy { $0.image?.renderingMode == .alwaysOriginal })
        invoke(dashboards[2])
        try await waitUntil { selected == .knowledge }
        for action in sections.dropFirst().flatMap(\.children).compactMap({ $0 as? UIAction }) {
            invoke(action)
            try await waitUntil { invoked.last == action.title }
        }
        XCTAssertEqual(invoked, ["Search", "Filter", "Settings", "New Session"])
    }

    func testRealDashboardHeaderScrollAndExistingDestinations() async throws {
        try await withDashboard { host in
            var menu = try await self.menuButton(in: host.view)
            XCTAssertEqual(menu.accessibilityLabel, "Dashboard menu")
            XCTAssertEqual(menu.preferredMenuElementOrder, .fixed, "The upward-opening popup preserves section order")
            let frame = menu.convert(menu.bounds, to: host.view)
            XCTAssertGreaterThan(frame.midX, host.view.bounds.midX, "The sole logo control is trailing")
            XCTAssertGreaterThan(frame.midY, host.view.bounds.height * 0.8, "The logo replaces the bottom-right plus button")
            XCTAssertEqual(frame.width, 56, accuracy: 0.5)
            XCTAssertEqual(frame.height, 56, accuracy: 0.5)
            let logo = try XCTUnwrap(menu.imageView)
            XCTAssertEqual(logo.bounds.width, 34, accuracy: 0.5)
            XCTAssertEqual(logo.bounds.height, 34, accuracy: 0.5)
            XCTAssertEqual(logo.center, CGPoint(x: 28, y: 28))
            try await self.waitUntil { self.views(UIScrollView.self, in: host.view).contains { $0.contentSize.height > $0.bounds.height } }
            let title = try XCTUnwrap(self.elements(in: host.view).first { $0.accessibilityLabel == "Tron" })
            XCTAssertLessThan(title.accessibilityFrame.midX, host.view.bounds.midX, "Tron is leading, not centered")
            XCTAssertTrue(title.accessibilityTraits.contains(.header))
            let titleFrame = title.accessibilityFrame
            XCTAssertFalse(self.elements(in: host.view).contains { $0.accessibilityLabel == "Search sessions" }, "No duplicate floating search control")
            try await self.attach(host.view, name: "dashboard-expanded-dark")

            let scroll = try XCTUnwrap(self.views(UIScrollView.self, in: host.view).first { $0.contentSize.height > $0.bounds.height })
            let original = scroll.contentOffset
            scroll.setContentOffset(CGPoint(x: original.x, y: original.y + 120), animated: false)
            try await self.waitUntil { scroll.contentOffset.y > original.y + 100 }
            try await self.attach(host.view, name: "dashboard-scrolled-dark")
            XCTAssertEqual(self.elements(in: host.view).first(where: { $0.accessibilityLabel == "Tron" })?.accessibilityFrame,
                           titleFrame, "The heading keeps its size and position after scrolling")
            XCTAssertEqual(menu.convert(menu.bounds, to: host.view), frame, "Scrolling never moves the menu hit target")
            self.invoke(try self.action("Automations", in: menu))
            try await self.waitUntil { self.views(UIButton.self, in: host.view).contains { $0.accessibilityValue == "Automations" } }
            menu = try await self.menuButton(in: host.view)
            self.invoke(try self.action("Sessions", in: menu))
            try await self.waitUntil {
                self.elements(in: host.view).first(where: { $0.accessibilityLabel == "Tron" })?.accessibilityFrame == titleFrame
            }
            menu = try await self.menuButton(in: host.view)

            let search = try self.action("Search", in: menu)
            self.invoke(search)
            try await self.waitUntil { self.views(UITextField.self, in: host.view).contains { $0.isFirstResponder } }
            host.view.endEditing(true)
            try await self.waitUntil { !self.views(UITextField.self, in: host.view).contains { $0.isFirstResponder } }

            for (name, expected) in [("Filter", "Filter Servers"), ("Settings", "Settings"), ("New Session", "New Session")] {
                self.invoke(try self.action(name, in: menu))
                try await self.waitUntil { host.presentedViewController != nil }
                let presented = try XCTUnwrap(host.presentedViewController)
                try await self.waitUntil { self.elements(in: presented.view).contains { $0.accessibilityLabel == expected } }
                await withCheckedContinuation { continuation in
                    host.dismiss(animated: false) { continuation.resume() }
                }
            }
        }
    }

    func testLightAccessibilityLayout() async throws {
        try await withDashboard(style: .light, dynamicType: .accessibility3) { host in
            let menu = try await self.menuButton(in: host.view)
            try await self.waitUntil { self.views(UIScrollView.self, in: host.view).contains { $0.contentSize.height > $0.bounds.height } }
            let title = try XCTUnwrap(self.elements(in: host.view).first { $0.accessibilityLabel == "Tron" })
            let titleFrame = title.accessibilityFrame
            XCTAssertLessThan(titleFrame.midX, host.view.bounds.midX)
            XCTAssertTrue(title.accessibilityTraits.contains(.header))
            XCTAssertFalse(title.accessibilityTraits.contains(.button))
            XCTAssertEqual(menu.bounds.size, CGSize(width: 56, height: 56))
            try await self.attach(host.view, name: "dashboard-expanded-light-accessibility")
            let scroll = try XCTUnwrap(self.views(UIScrollView.self, in: host.view).first { $0.contentSize.height > $0.bounds.height })
            let original = scroll.contentOffset
            scroll.setContentOffset(CGPoint(x: original.x, y: original.y + 40), animated: false)
            try await self.waitUntil { scroll.contentOffset.y > original.y + 30 }
            try await self.attach(host.view, name: "dashboard-mid-scroll-light-accessibility")
            XCTAssertEqual(self.elements(in: host.view).first(where: { $0.accessibilityLabel == "Tron" })?.accessibilityFrame,
                           titleFrame, "Accessibility sizing stays stable during the blur fade")
        }
    }

    func testNativePopupOpensAboveTheFloatingLogoInSectionOrder() async throws {
        try await withDashboard { host in
            let menu = try await self.menuButton(in: host.view)
            let window = try XCTUnwrap(host.view.window)
            menu.performPrimaryAction()
            defer { menu.interactions.compactMap { $0 as? UIContextMenuInteraction }.forEach { $0.dismissMenu() } }
            let titles = ["Sessions", "Automations", "Knowledge", "Search", "Filter", "Settings", "New Session"]
            try await self.waitUntil {
                titles.allSatisfy { title in self.elements(in: window).contains { $0.accessibilityLabel == title } }
            }
            let frames = try titles.map { title in
                try XCTUnwrap(self.elements(in: window).first { $0.accessibilityLabel == title }).accessibilityFrame
            }
            for (previous, next) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThan(previous.midY, next.midY, "The upward popup must not reverse the requested section order")
            }
            try await self.attach(window, name: "dashboard-logo-popup")
        }
    }

    private func action(_ title: String, in button: UIButton) throws -> UIAction {
        let children = try XCTUnwrap(button.menu).children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }
        return try XCTUnwrap(children.compactMap { $0 as? UIAction }.first { $0.title == title })
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

    private func elements(in view: UIView) -> [NSObject] {
        var result = view.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
        if view.isAccessibilityElement { result.append(view) }
        return result + view.subviews.flatMap { elements(in: $0) }
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
        try await waitUntil { !self.views(UIButton.self, in: host.view).isEmpty }
        host.view.layoutIfNeeded()
        try await check(host)
    }
}
