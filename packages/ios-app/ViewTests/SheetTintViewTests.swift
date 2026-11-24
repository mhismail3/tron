import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SheetTintViewTests: ShuffledTestCase {
    func testSettingsSheetToolbarsTakeTheirTitleTint() async throws {
        try await mounted(["-tron-settings-navigation-fixture"], theme: .burgundy) { app in
            try await assertToolbarTint(app, title: "Settings")
            for title in ["Connections", "MCP Servers", "Appearance"] {
                _ = try await revealed(app, "settings-link-\(title)")
                assertBurgundy(try await app.inked("\(title) row icon") {
                    app.element("settings-link-\(title)").map(\.accessibilityFrame).map { CGRect(x: $0.minX, y: $0.minY, width: 48, height: $0.height) }
                }, "\(title) row icon")
                try await app.activate("settings-link-\(title)")
                assertBurgundy(try await assertToolbarTint(app, title: title), "\(title) sheet title")
                try await app.activate("Done")
                try await app.until("Settings returns") { app.navigationTitle("Settings") != nil }
            }
        }
    }

    func testNestedSessionsRetentionOpensAndPersistsInLightAndDark() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-mac-settings-fixture", "-settings-nested"] + (dark ? ["-settings-dark"] : [])) { app in
                try await app.activate("Open Settings")
                _ = try await revealed(app, "settings-link-Appearance")
                try await app.activate("settings-link-Appearance")
                try await assertToolbarTint(app, title: "Appearance")
            }
        }
    }

    func testNestedHistoryMenuOpensEveryDestinationInLightAndDark() async throws {
        for appearance in ["light", "dark"] {
            try await mounted(["-tron-session-configuration-fixture", "-fixture-appearance", appearance]) { app in
                try await app.activate("Stop session")
                _ = try await revealed(app, "Session History")
                try await app.activate("Session History")
                try await app.until("the history row") { app.element("history-row-fixture-prompt") != nil }
                try await assertToolbarTint(app, title: "Session History")
            }
        }
    }

    func testDashboardSheetToolbarsTakeTheirTitleTint() async throws {
        try await mounted(["-tron-accessibility-fixture", "-fixture-dashboard"]) { app in
            try await performDashboardAction(app, "Automations")
            try await assertToolbarTint(app, title: "Automations")
            try await app.activate("automations.new")
            try await assertToolbarTint(app, title: "New Automation")
        }
    }

    func testManageHomeToolbarsTakeTheirTitleTint() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            try await assertToolbarTint(app, title: "Manage Home")
            _ = try await revealed(app, "home-manage-memory-browser")
            try await app.activate("home-manage-memory-browser")
            try await app.until("Memory opens") { app.element("home-sheet-done-memory") != nil }
            try await assertToolbarTint(app, title: "Memory")
        }
    }

    func testSheetTopBlurTracksScrollFromInvisibleAtRest() async throws {
        try await mounted(["-tron-settings-navigation-fixture"], contentSize: .accessibilityExtraExtraExtraLarge) { @MainActor app in
            var found: UIScrollView?
            try await app.until("the Settings scroll view") {
                found = MountedFixture.views(UIScrollView.self, in: app.top)
                    .filter { $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom
                        - $0.bounds.height > TronTopBlurStyle.sheet.height + 8 }
                    .max { $0.bounds.height < $1.bounds.height }
                return found != nil
            }
            let scroll = try XCTUnwrap(found)
            let top = -scroll.adjustedContentInset.top
            @MainActor func blur(at offset: CGFloat) async throws -> Float {
                scroll.setContentOffset(CGPoint(x: 0, y: top + offset), animated: false)
                var opacity: Float = -1
                try await app.until("the top blur at \(offset)") {
                    let next = MountedFixture.views(VariableBackdropBlurView.self, in: app.top).map { view in
                        sequence(first: view.layer, next: \.superlayer).reduce(Float(1)) { $0 * $1.opacity }
                    }.max() ?? 0
                    defer { opacity = next }
                    return next == opacity
                }
                return opacity
            }
            let rest = try await blur(at: 0)
            XCTAssertEqual(rest, 0, accuracy: 0.01, "The sheet top blur shows at rest")
            let pull = try await blur(at: -40)
            XCTAssertEqual(pull, 0, accuracy: 0.01, "Pull-down overscroll shows the top blur")
            let mid = try await blur(at: TronTopBlurStyle.sheet.height / 2)
            XCTAssertEqual(mid, 0.5, accuracy: 0.05, "The top blur is not proportional to the scroll")
            let full = try await blur(at: TronTopBlurStyle.sheet.height + 8)
            XCTAssertEqual(full, 1, accuracy: 0.01, "The top blur does not reach full strength after scrolling")
            let back = try await blur(at: 0)
            XCTAssertEqual(back, 0, accuracy: 0.01, "The top blur still shows after scrolling back")
        }
    }

    @discardableResult
    func assertToolbarTint(_ app: MountedFixture, title: String, file: StaticString = #filePath,
                           line: UInt = #line) async throws -> [Double] {
        let tint = try await app.inked("\(title)'s title") {
            app.navigationTitle(title).map(\.accessibilityFrame).flatMap { app.window.bounds.contains($0) ? $0 : nil }
        }
        let image = app.render()
        let actions = app.navigationTitle(title).map(app.toolbarActions) ?? []
        XCTAssertFalse(actions.isEmpty, "\(title) has no enabled toolbar action\n\(app.tree())", file: file, line: line)
        for action in actions {
            guard let ink = app.ink(action.accessibilityFrame, image: image) else {
                XCTFail("\(title): no inked pixels in toolbar action '\(action.accessibilityLabel ?? "")'", file: file, line: line)
                continue
            }
            let distance = zip(ink, tint).map { abs($0 - $1) }.max() ?? 1
            XCTAssertLessThan(distance, 0.12,
                              "\(title): toolbar action '\(action.accessibilityLabel ?? "")' \(ink) is not the title's tint \(tint)",
                              file: file, line: line)
        }
        return tint
    }

    private func assertBurgundy(_ ink: [Double], _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(ink[0], ink[2], "\(context) \(ink) is not the burgundy theme", file: file, line: line)
        XCTAssertGreaterThan(ink[2], ink[1], "\(context) \(ink) is not the burgundy theme", file: file, line: line)
    }
}

@MainActor
func revealed(_ app: MountedFixture, _ key: String) async throws -> NSObject {
    var node: NSObject?
    try await app.until("\(key) exists") {
        node = app.element(key)
        return node != nil
    }
    try await app.reveal(node!)
    return app.element(key) ?? node!
}

@MainActor
func menuAction(_ title: String, in menu: UIMenu) -> UIAction? {
    for child in menu.children {
        if let action = child as? UIAction, action.title == title { return action }
        if let nested = child as? UIMenu, let action = menuAction(title, in: nested) { return action }
    }
    return nil
}

@MainActor
func menuActionTitles(_ menu: UIMenu) -> [String] {
    menu.children.flatMap { child -> [String] in
        if let action = child as? UIAction { return [action.title] }
        if let nested = child as? UIMenu { return menuActionTitles(nested) }
        return []
    }
}

@MainActor
func dashboardMenu(_ app: MountedFixture) async throws -> UIMenu {
    try await app.until("the dashboard menu") { app.element("dashboard.menu") is UIButton }
    guard let menu = (app.element("dashboard.menu") as? UIButton)?.menu else {
        throw FixtureNotReady(description: "the dashboard menu has no menu\n\(app.tree())")
    }
    return menu
}

@MainActor
func performDashboardAction(_ app: MountedFixture, _ title: String) async throws {
    let menu = try await dashboardMenu(app)
    guard let action = menuAction(title, in: menu) else {
        throw FixtureNotReady(description: "the dashboard menu offers no \(title) action\n\(app.tree())")
    }
    action.perform(NSSelectorFromString("performWithSender:target:"), with: nil, with: nil)
}

@MainActor
func openManageHome(_ app: MountedFixture) async throws {
    try await app.activate("home-pinned-row")
    try await app.activate("session-context-button")
    try await app.until("Manage Home opens") { app.element("home-manage-state") != nil }
    try await app.waitForTopSheetToSettle()
}
