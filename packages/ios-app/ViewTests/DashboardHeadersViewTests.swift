import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class DashboardHeadersViewTests: ShuffledTestCase {
    func testDashboardHeadersAndSpacing() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
                              + (dark ? ["-home-dark"] : [])) { app in
                try await app.until("the dashboard sections") {
                    app.element("session-row-home-shell-fixture:worker-running") != nil
                        && app.element("In Progress") != nil && app.element("Recently Completed") != nil
                }
                let frames = try await app.still("the dashboard layout") {
                    ["session-row-home-shell-fixture:worker-running", "In Progress", "Recently Completed"].compactMap { app.element($0) }
                        .flatMap { [Double($0.accessibilityFrame.minY), Double($0.accessibilityFrame.maxY)] }
                }
                XCTAssertEqual(frames.count, 6, app.tree())
                guard frames.count == 6 else { return }
                let (rowMinY, rowMaxY, headingMaxY, completedMinY) = (frames[0], frames[1], frames[3], frames[4])
                XCTAssertEqual(rowMinY - headingMaxY, 0, accuracy: 1, "Keep the approved header-to-row layout")
                XCTAssertGreaterThan(completedMinY - rowMaxY, 15, "Keep distinct sections, not an undifferentiated row stack")
            }
        }
    }

    func testSettingsIsOneFlatListWithTerminalInToolbar() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-settings-fixture", "-settings-nested", "-settings-expanded-review",
                               "-fixture-appearance", dark ? "dark" : "light"]) { app in
                try await app.activate("Open Settings")
                try await app.until("Settings opens") { app.navigationTitle("Settings") != nil }
                try await app.waitForTopSheetToSettle()
                for header in ["This iPhone", "Accounts", "Agent & Tools", "System"] {
                    XCTAssertNil(app.staticText(header), "Settings has no section header \(header)\n\(app.tree())")
                }
                let rows = ["Appearance", "Connections", "Model Providers", "MCP Servers"].map { "settings-link-\($0)" }
                try await app.until("every Settings row") { rows.allSatisfy { app.element($0) != nil } }
                let tops = rows.compactMap { app.element($0)?.accessibilityFrame.minY }
                XCTAssertEqual(tops, tops.sorted(), "Rows keep their order")
                let gaps = zip(tops.dropFirst(), tops).map { $0 - $1 }
                XCTAssertLessThan((gaps.max() ?? 0) - (gaps.min() ?? 0), 1, "One evenly spaced list, no group gaps: \(gaps)")
                let terminal = app.button("settings-mac-terminal")
                XCTAssertNotNil(terminal, app.tree())
                XCTAssertEqual(terminal?.accessibilityLabel, "Mac Terminal")
                let actions = app.navigationTitle("Settings").map(app.toolbarActions) ?? []
                XCTAssertTrue(actions.contains { MountedFixture.identifier($0) == "settings-mac-terminal" }, "The terminal button sits in the toolbar\n\(app.tree())")
                let bell = actions.first { $0.accessibilityLabel?.hasPrefix("Open notifications") == true }
                XCTAssertNotNil(bell, app.tree())
                if let bell, let terminal {
                    XCTAssertLessThan(bell.accessibilityFrame.maxX, terminal.accessibilityFrame.minX, "Terminal follows the alerts button")
                    XCTAssertLessThan(terminal.accessibilityFrame.maxX, app.navigationTitle("Settings")!.accessibilityFrame.minX, "Terminal is a leading action")
                }
            }
        }
    }
}
