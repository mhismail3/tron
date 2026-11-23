import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeDashboardViewTests: ShuffledTestCase {
    func testNewWorkerAppearsWithoutRelaunch() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                           "-home-dashboard-new-worker"]) { app in
            try await app.until("the new worker row") { app.button("session-row-home-shell-fixture:worker-new") != nil }
            XCTAssertEqual(app.element("fixture.home-task-list-reads")?.accessibilityLabel, "task-list-reads:0", app.tree())
        }
    }

    func testHomeButtonShowsWaitingForUser() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                           "-home-phase-active", "-home-waiting"]) { app in
            try await app.until("the Home button reads Waiting for you") {
                app.element("dashboard.menu")?.accessibilityValue == "Waiting for you"
            }
        }
    }
}
