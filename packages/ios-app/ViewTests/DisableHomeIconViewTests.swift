import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class DisableHomeIconViewTests: ShuffledTestCase {
    func testDisableHomeIconIsDestructiveRedInBothAppearances() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-task-history-review"]
                              + (dark ? ["-home-dark"] : [])) { app in
                try await openManageHome(app)
                _ = try await revealed(app, "home-manage-settings")
                try await app.activate("home-manage-settings")
                try await app.until("Home Settings opens") { app.element("home-manage-disable") != nil }
                try await app.expandTopSheet()
                for _ in 0..<8 {
                    let node = try await revealed(app, "home-manage-disable")
                    if app.window.bounds.insetBy(dx: 0, dy: 50).contains(node.accessibilityFrame) { break }
                }
                @MainActor func redCount() -> Double? {
                    guard let row = app.element("home-manage-disable") else { return nil }
                    var area = row.accessibilityFrame; area.size.width = 50
                    guard app.window.bounds.contains(area), let pixels = app.pixels(area) else { return nil }
                    return Double(pixels.filter { $0[0] > $0[1] * 1.4 && $0[0] > $0[2] * 1.4 && $0[0] > 60 }.count)
                }
                let red = try await app.still("Disable Home's icon") { redCount().map { [$0 / 1000] } }
                XCTAssertGreaterThan(red[0] * 1000, 20, "The decorative icon paints destructive red, not inherited green")
            }
        }
    }
}
