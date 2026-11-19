import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SheetTintViewTests: ShuffledTestCase {
    func testSettingsSheetToolbarsTakeTheirTitleTint() async throws {
        try await mounted(["-tron-settings-navigation-fixture"], theme: .burgundy) { app in
            try await assertToolbarTint(app, title: "Global Settings")
            for title in ["Connections", "MCP Servers", "Appearance"] {
                _ = try await revealed(app, "settings-link-\(title)")
                assertBurgundy(try await app.inked("\(title) row icon") {
                    app.element("settings-link-\(title)").map(\.accessibilityFrame).map { CGRect(x: $0.minX, y: $0.minY, width: 48, height: $0.height) }
                }, "\(title) row icon")
                try await app.activate("settings-link-\(title)")
                assertBurgundy(try await assertToolbarTint(app, title: title), "\(title) sheet title")
                try await app.activate("Done")
                try await app.until("Global Settings returns") { app.navigationTitle("Global Settings") != nil }
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
            try await app.until("the dashboard menu") { app.element("dashboard.menu") is UIButton }
            guard let menu = (app.element("dashboard.menu") as? UIButton)?.menu,
                  let automations = Self.action("Automations", in: menu) else {
                return XCTFail("The dashboard menu offers no Automations action\n\(app.tree())")
            }
            automations.perform(NSSelectorFromString("performWithSender:target:"), with: nil, with: nil)
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

    private static func action(_ title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title { return action }
            if let nested = child as? UIMenu, let action = action(title, in: nested) { return action }
        }
        return nil
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
func openManageHome(_ app: MountedFixture) async throws {
    try await app.activate("home-pinned-row")
    try await app.activate("session-context-button")
    try await app.until("Manage Home opens") { app.element("home-manage-state") != nil }
    try await app.expandTopSheet()
}
