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

    func testGlobalSettingsGroupHeaders() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review",
                               "-fixture-appearance", dark ? "dark" : "light"]) { app in
                try await app.activate("Open Settings")
                try await app.until("Appearance") { app.element("Appearance") != nil }
                for title in ["This iPhone", "Accounts", "Agent & Tools", "System"] {
                    _ = try await revealed(app, title)
                    XCTAssertNotNil(app.element(title), "Missing Global Settings group: \(title)\n\(app.tree())")
                }
            }
        }
    }
}
