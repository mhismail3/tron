import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeDelegationViewTests: ShuffledTestCase {
    func testManageHomeShowsDelegationOnlyWhenThereIsSomethingToActOnAndNeverCoversItsTitle() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-permissions-granted"]) { app in
            try await openManageHome(app)
            var row: NSObject?
            try await app.until("Home delegation shows in Manage Home for an active scope") {
                row = app.element("home-delegation")
                return row != nil
            }
            try await app.reveal(row!)
            for rowID in ["home-delegation", "home-delegation-grant-grant-one"] {
                var title: NSObject?
                var button: NSObject?
                try await app.until("\(rowID) lays out its title and Revoke") {
                    title = app.element("\(rowID)-title")
                    button = app.element("\(rowID)-action")
                    return title != nil && button != nil
                }
                let titleFrame = title!.accessibilityFrame
                XCTAssertGreaterThan(titleFrame.width, 0, "\(rowID) has a visible title\n\(app.tree())")
                XCTAssertFalse(titleFrame.intersects(button!.accessibilityFrame),
                               "Revoke is drawn over the \(rowID) title\n\(app.tree())")
                if let status = app.element("\(rowID)-status") {
                    XCTAssertFalse(titleFrame.intersects(status.accessibilityFrame), "The status pill covers the \(rowID) title\n\(app.tree())")
                }
            }
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-permissions-granted"]) { app in
            try await app.activate("home-pinned-row")
            try await app.activate("Settings")
            try await app.until("Settings opens") { app.element("settings-link-MCP Servers") != nil }
            for _ in 0..<10 { await MountedFixture.nextFrame() }
            XCTAssertNil(app.element("settings-home-delegation"), "Settings has no Home delegation row\n\(app.tree())")
            XCTAssertNil(app.element("home-delegation"), "Settings has no Home delegation row\n\(app.tree())")
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            try await app.until("Manage Home read Home's task permissions") {
                (app.element("fixture.home-read-counts", in: app.window)?.accessibilityLabel ?? "").contains("home.taskPermissions=1")
            }
            for _ in 0..<10 { await MountedFixture.nextFrame() }
            XCTAssertNil(app.element("home-delegation"), "No scope and no grants shows nothing\n\(app.tree())")
            XCTAssertNil(app.staticText("Not authorized"), "There is no Not authorized row\n\(app.tree())")
        }
    }

    private func openManageHome(_ app: MountedFixture) async throws {
        try await app.activate("home-pinned-row")
        try await app.activate("session-context-button")
        try await app.until("Manage Home opens") { app.element("home-manage-state") != nil }
        try await app.waitForTopSheetToSettle()
    }
}
